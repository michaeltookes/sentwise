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
/// which should only be enabled once the Clerk test user has a durable Worker
/// entitlement or trial bypass. Otherwise a recurring push-to-main run would
/// start passing today and fail permanently after the normal trial expires.
///
/// The tests mint a short-lived Clerk JWT during each run using Clerk's test
/// email-code flow, avoiding a stale session-token repository secret.
final class ManagedInferenceLiveTests: XCTestCase {

    /// A deterministic Clerk test email. `+clerk_test` triggers test mode; the
    /// universal code below verifies without sending email.
    private static let testEmail = "sentwise-live+clerk_test@sentwise.ai"
    private static let testCode = "424242"

    private func liveConfig(
        requiresDurableDraftEntitlement: Bool = false
    ) async throws -> (token: String, baseURL: URL) {
        let env = ProcessInfo.processInfo.environment
        try requireTruthy("SENTWISE_LIVE_MANAGED_INFERENCE", in: env)
        try requireTruthy("SENTWISE_LIVE_CLERK_TEST", in: env)
        if requiresDurableDraftEntitlement {
            try requireTruthy("SENTWISE_LIVE_MANAGED_DRAFT", in: env)
        }

        guard
            let urlString = env["SENTWISE_INFERENCE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !urlString.isEmpty,
            let baseURL = URL(string: urlString)
        else {
            throw XCTSkip("Set SENTWISE_INFERENCE_URL to run live managed-inference tests.")
        }
        return (try await mintLiveSessionToken(), baseURL)
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

    private func mintLiveSessionToken() async throws -> String {
        let clerk = ClerkClient()
        let handle = try await clerk.sendEmailCode(email: Self.testEmail, clientToken: "")
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
        XCTAssertGreaterThan(quota.limit, 0, "a live account should carry a positive weekly limit")
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

    func testLiveDraftReturnsText() async throws {
        let (token, baseURL) = try await liveConfig(requiresDurableDraftEntitlement: true)
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
