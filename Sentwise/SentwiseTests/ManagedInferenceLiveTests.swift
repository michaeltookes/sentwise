import XCTest
@testable import Sentwise

/// A `ManagedSessionProviding` returning a pre-obtained live session token.
private struct EnvSessionProvider: ManagedSessionProviding {
    let token: String
    func currentSessionToken() async throws -> String { token }
}

/// End-to-end tests against the deployed `sentwise-service` Worker. Skipped
/// unless BOTH env vars are set, so CI and normal runs stay offline:
///   SENTWISE_LIVE_CLERK_SESSION_TOKEN  — a real Clerk session JWT
///   SENTWISE_INFERENCE_URL             — the deployed Worker base URL
///
/// Obtain a session token by signing in through the app (or via Clerk) and
/// reading the minted token; it is short-lived, so run these promptly.
final class ManagedInferenceLiveTests: XCTestCase {

    private func liveConfig() throws -> (token: String, baseURL: URL) {
        let env = ProcessInfo.processInfo.environment
        guard
            let token = env["SENTWISE_LIVE_CLERK_SESSION_TOKEN"], !token.isEmpty,
            let urlString = env["SENTWISE_INFERENCE_URL"], let baseURL = URL(string: urlString)
        else {
            throw XCTSkip("Set SENTWISE_LIVE_CLERK_SESSION_TOKEN and SENTWISE_INFERENCE_URL to run live tests.")
        }
        return (token, baseURL)
    }

    func testLiveMeReturnsAccountAndTrial() async throws {
        let (token, baseURL) = try liveConfig()
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
        let (token, baseURL) = try liveConfig()
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
        let (token, baseURL) = try liveConfig()
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
        let (token, baseURL) = try liveConfig()
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
