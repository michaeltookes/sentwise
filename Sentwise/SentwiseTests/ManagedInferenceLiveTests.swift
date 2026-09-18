import XCTest
@testable import Sentwise

/// A `ManagedSessionProviding` returning a freshly minted live session token.
private struct EnvSessionProvider: ManagedSessionProviding {
    let token: String
    func currentSessionToken() async throws -> String { token }
}

/// End-to-end tests against the deployed `sentwise-service` Worker. Skipped
/// unless all gates are set, so CI and normal runs stay offline:
///   SENTWISE_LIVE_MANAGED_INFERENCE — explicit Worker live-test gate
///   SENTWISE_LIVE_CLERK_TEST        — enables the Clerk test email-code flow
///   SENTWISE_INFERENCE_URL          — the deployed Worker base URL
///
/// `testLiveDraftReturnsText` also requires `SENTWISE_LIVE_MANAGED_DRAFT`,
/// plus `SENTWISE_LIVE_MANAGED_DRAFT_EMAIL`, a Clerk test user with a durable
/// Worker entitlement or trial bypass. Otherwise a recurring push-to-main run
/// would start passing today and fail permanently after the normal trial
/// expires.
///
/// `testLiveManageBillingReturnsPortalURL` requires
/// `SENTWISE_LIVE_MANAGED_PORTAL`, plus `SENTWISE_LIVE_MANAGED_PORTAL_EMAIL`, a
/// subscribed Clerk test user. It is read-only: it fetches the fresh portal link
/// from the Worker but never opens the URL or touches billing controls.
///
/// The tests mint a short-lived Clerk JWT during each run using Clerk's test
/// email-code flow, avoiding a stale session-token repository secret.
final class ManagedInferenceLiveTests: XCTestCase {

    private enum LiveAccount {
        case accountShape
        case durableDraft
        case subscribedPortal
    }

    /// A deterministic Clerk test email for account-shape checks. `+clerk_test`
    /// triggers test mode; the universal code below verifies without sending
    /// email. Draft checks use `SENTWISE_LIVE_MANAGED_DRAFT_EMAIL` instead so
    /// the recurring spend payload can point at a nonexpiring entitled user.
    private static let accountShapeTestEmail = "sentwise-live+clerk_test@sentwise.ai"
    private static let testCode = "424242"
    private static let customerPortalHosts: Set<String> = [
        "customer-portal.paddle.com",
        "sandbox-customer-portal.paddle.com"
    ]
    private static let portalSessionIDPrefix = "cpl_"
    private static let paddleIDBodyLength = 26
    private static let authenticatedPortalActions: Set<String> = [
        "overview",
        "cancel_subscription",
        "update_subscription_payment_method"
    ]
    private static let subscriptionScopedPortalActions: Set<String> = [
        "cancel_subscription",
        "update_subscription_payment_method"
    ]

    private func liveConfig(
        account: LiveAccount = .accountShape
    ) async throws -> (token: String, baseURL: URL) {
        let env = ProcessInfo.processInfo.environment
        try requireTruthy("SENTWISE_LIVE_MANAGED_INFERENCE", in: env)
        try requireTruthy("SENTWISE_LIVE_CLERK_TEST", in: env)
        switch account {
        case .accountShape:
            break
        case .durableDraft:
            try requireTruthy("SENTWISE_LIVE_MANAGED_DRAFT", in: env)
        case .subscribedPortal:
            try requireTruthy("SENTWISE_LIVE_MANAGED_PORTAL", in: env)
        }

        guard
            let urlString = env["SENTWISE_INFERENCE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !urlString.isEmpty,
            let baseURL = URL(string: urlString)
        else {
            throw XCTSkip("Set SENTWISE_INFERENCE_URL to run live managed-inference tests.")
        }
        let email = try clerkTestEmail(in: env, account: account)
        return (try await mintLiveSessionToken(email: email), baseURL)
    }

    private func requireTruthy(_ name: String, in env: [String: String]) throws {
        if name == "SENTWISE_LIVE_MANAGED_DRAFT" {
            guard Self.isTruthy(env[name]) else {
                throw XCTSkip(
                    "Set SENTWISE_LIVE_MANAGED_DRAFT=1 only for a Clerk test user with durable draft entitlement."
                )
            }
            return
        }
        if name == "SENTWISE_LIVE_MANAGED_PORTAL" {
            guard Self.isTruthy(env[name]) else {
                throw XCTSkip(
                    "Set SENTWISE_LIVE_MANAGED_PORTAL=1 only for a subscribed Clerk test user."
                )
            }
            return
        }
        guard Self.isTruthy(env[name]) else {
            throw XCTSkip("Set \(name)=1 to run live managed-inference tests.")
        }
    }

    private static func isTruthy(_ value: String?) -> Bool {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "1" || normalized == "true" || normalized == "yes"
    }

    private static func authenticatedPortalSessionURLIssue(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "https" else {
            return "expected an https Paddle portal-session URL, got \(url)"
        }
        guard
            let host = url.host?.lowercased(),
            customerPortalHosts.contains(host)
        else {
            return "expected an exact Paddle customer portal host, got \(url)"
        }

        let sessionPathComponents = url.pathComponents.filter { $0 != "/" }
        guard
            sessionPathComponents.count == 1,
            let sessionID = sessionPathComponents.first,
            isPaddleID(sessionID, prefix: portalSessionIDPrefix)
        else {
            return "expected a Paddle portal-session path like /cpl_..., got \(url)"
        }

        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let queryItems = components.queryItems
        else {
            return "expected portal-session query parameters, got \(url)"
        }
        let query = Dictionary(queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })

        guard
            let action = query["action"],
            authenticatedPortalActions.contains(action)
        else {
            return "expected a documented Paddle portal-session action, got \(url)"
        }
        guard
            let token = query["token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            token.hasPrefix("pga_")
        else {
            return "expected a temporary Paddle portal-session token, got \(url)"
        }

        if subscriptionScopedPortalActions.contains(action),
           !isPaddleID(query["subscription_id"], prefix: "sub_") {
            return "expected subscription-scoped Paddle portal URL to include subscription_id, got \(url)"
        }

        return nil
    }

    private static func isPaddleID(_ value: String?, prefix: String) -> Bool {
        guard let value, value.hasPrefix(prefix) else { return false }
        let idBody = value.dropFirst(prefix.count)
        return idBody.count == paddleIDBodyLength
            && idBody.allSatisfy { $0.isLowercase || $0.isNumber }
    }

    private func clerkTestEmail(in env: [String: String], account: LiveAccount) throws -> String {
        switch account {
        case .accountShape:
            return Self.accountShapeTestEmail
        case .durableDraft:
            return try requiredEmail(
                "SENTWISE_LIVE_MANAGED_DRAFT_EMAIL",
                in: env,
                skipMessage: "Set SENTWISE_LIVE_MANAGED_DRAFT_EMAIL "
                    + "to a Clerk test user with durable draft entitlement."
            )
        case .subscribedPortal:
            return try requiredEmail(
                "SENTWISE_LIVE_MANAGED_PORTAL_EMAIL",
                in: env,
                skipMessage: "Set SENTWISE_LIVE_MANAGED_PORTAL_EMAIL to a subscribed Clerk test user."
            )
        }
    }

    private func requiredEmail(
        _ name: String,
        in env: [String: String],
        skipMessage: String
    ) throws -> String {
        guard
            let email = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !email.isEmpty
        else {
            throw XCTSkip(skipMessage)
        }
        return email
    }

    private func mintLiveSessionToken(email: String) async throws -> String {
        let clerk = ClerkClient()
        let handle = try await clerk.sendEmailCode(email: email, clientToken: "")
        let verified = try await clerk.verifyEmailCode(
            signInId: handle.signInId,
            code: Self.testCode,
            clientToken: handle.clientToken,
            flow: handle.flow
        )
        let minted = try await clerk.mintSessionToken(
            sessionId: verified.sessionId,
            clientToken: verified.clientToken
        )
        XCTAssertFalse(minted.jwt.isEmpty, "expected a freshly minted session JWT")
        return minted.jwt
    }

    func testLiveMeReturnsAccountAndTrial() async throws {
        let (token, baseURL) = try await liveConfig()
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/me"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        XCTAssertEqual(status, 200, "unexpected /v1/me status; body: \(String(bytes: data, encoding: .utf8) ?? "")")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["userId"] as? String)
        XCTAssertNotNil(object["trial"] as? [String: Any])
    }

    /// Verifies the `/v1/me` quota block's shape when the deployed Worker returns
    /// one. Tolerates its absence so the app half can land before the service half
    /// (item 56b) — an older Worker build simply omits `quota`.
    func testLiveMeQuotaShapeWhenPresent() async throws {
        let (token, baseURL) = try await liveConfig()
        let client = ManagedInferenceClient(
            sessionProvider: EnvSessionProvider(token: token),
            transport: URLSessionTransport()
        )

        let quota = try await client.fetchAccountQuota(meEndpoint: baseURL.appendingPathComponent("v1/me"))
        guard let quota else {
            throw XCTSkip("Deployed Worker does not return a quota block yet (service half of 56b not live).")
        }

        XCTAssertFalse(quota.unit.isEmpty, "quota.unit should be a user-facing unit")
        XCTAssertGreaterThanOrEqual(quota.used, 0)
        XCTAssertGreaterThan(quota.limit, 0, "a live account should carry a positive monthly limit")
        XCTAssertTrue(quota.hasKnownReset, "quota.resetsAt should be a valid ISO-8601 instant")
    }

    /// Verifies the `/v1/me` subscription block's shape when the deployed Worker
    /// returns one (item 73). Tolerates its absence so the app half can land
    /// before the service half — an older Worker build simply omits `subscription`.
    func testLiveMeSubscriptionShapeWhenPresent() async throws {
        let (token, baseURL) = try await liveConfig()
        let client = ManagedInferenceClient(
            sessionProvider: EnvSessionProvider(token: token),
            transport: URLSessionTransport()
        )

        let status = try await client.fetchAccountStatus(meEndpoint: baseURL.appendingPathComponent("v1/me"))
        guard let subscription = status.subscription else {
            throw XCTSkip("Deployed Worker does not return a subscription block yet (service half of 73 not live).")
        }

        // Enums decode with an `.unknown` fallback, so any raw value is tolerated;
        // assert only that the block is structurally present and self-consistent.
        if subscription.status == .active {
            XCTAssertNotNil(subscription.renewsAt, "an active subscription should carry renewsAt")
        }
        XCTAssertNotNil(status.userID, "a live account should carry a userId")
    }

    func testPortalSessionURLValidationAcceptsAuthenticatedPaddleLinks() throws {
        let overview = try XCTUnwrap(URL(string:
            "https://customer-portal.paddle.com/cpl_01j7zbyqs3vah3aafp4jf62qaw"
                + "?action=overview&token=pga_test"
        ))
        XCTAssertNil(Self.authenticatedPortalSessionURLIssue(for: overview))

        let subscriptionScoped = try XCTUnwrap(URL(string:
            "https://sandbox-customer-portal.paddle.com/cpl_01j7zbyqs3vah3aafp4jf62qaw"
                + "?action=update_subscription_payment_method"
                + "&subscription_id=sub_01h04vsc0qhwtsbsxh3422wjs4"
                + "&token=pga_test"
        ))
        XCTAssertNil(Self.authenticatedPortalSessionURLIssue(for: subscriptionScoped))
    }

    func testPortalSessionURLValidationRejectsSignInFallbacks() throws {
        let fallbackURLs = [
            "https://paddle.com/customer-portal",
            "https://customer-portal.paddle.com/",
            "https://customer-portal.paddle.com/login?action=overview&token=pga_test",
            "https://customer-portal.paddle.com/cpl_01j7zbyqs3vah3aafp4jf62qaw?action=overview",
            "https://customer-portal.paddle.com/cpl_01j7zbyqs3vah3aafp4jf62qaw"
                + "?action=update_subscription_payment_method&token=pga_test"
        ]

        for rawURL in fallbackURLs {
            let url = try XCTUnwrap(URL(string: rawURL))
            XCTAssertNotNil(
                Self.authenticatedPortalSessionURLIssue(for: url),
                "expected validator to reject \(rawURL)"
            )
        }
    }

    func testLiveManageBillingReturnsPortalURL() async throws {
        let (token, baseURL) = try await liveConfig(account: .subscribedPortal)
        let client = ManagedInferenceClient(
            sessionProvider: EnvSessionProvider(token: token),
            transport: URLSessionTransport()
        )

        let url = try await client.fetchManageBillingURL(
            endpoint: baseURL.appendingPathComponent("v1/paddle/manage-billing")
        )

        XCTAssertNil(Self.authenticatedPortalSessionURLIssue(for: url))
    }

    func testLiveDraftReturnsText() async throws {
        let (token, baseURL) = try await liveConfig(account: .durableDraft)
        let client = ManagedInferenceClient(
            sessionProvider: EnvSessionProvider(token: token),
            transport: URLSessionTransport(),
            endpoint: baseURL.appendingPathComponent("v1/draft")
        )

        let response = try await client.complete(LLMRequest(
            system: "Reply with a single friendly word.",
            messages: [LLMMessage(role: .user, content: "Say hello.")],
            model: "claude-sonnet-4-6",
            maxTokens: 64,
            temperature: 0
        ))

        XCTAssertFalse(response.text.isEmpty, "live draft returned empty text")
    }
}
