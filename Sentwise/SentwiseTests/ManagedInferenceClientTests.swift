import XCTest
@testable import Sentwise

/// A `ManagedSessionProviding` double with a fixed token or a preset error.
private struct StubSessionProvider: ManagedSessionProviding {
    var token: String = "session-jwt"
    var error: Error?

    func currentSessionToken() async throws -> String {
        if let error { throw error }
        return token
    }
}

private actor RecordingSessionProvider: ManagedSessionProviding {
    private(set) var didInvalidate = false

    func currentSessionToken() async throws -> String {
        "session-jwt"
    }

    func invalidateSession() async {
        didInvalidate = true
    }
}

final class ManagedInferenceClientTests: XCTestCase {

    private func sampleRequest() -> LLMRequest {
        LLMRequest(
            system: "You write like the user.",
            messages: [LLMMessage(role: .user, content: "Draft a reply.")],
            model: "claude-sonnet-4-6",
            maxTokens: 512,
            temperature: 0.6
        )
    }

    private func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(string.utf8), headers: headers)
    }

    func testSendsBearerTokenAndMapsResponse() async throws {
        let transport = FakeLLMTransport(response: json(
            #"{"text":"Hi Marcus,","usage":{"inputTokens":40,"outputTokens":12}}"#
        ))
        let client = ManagedInferenceClient(
            sessionProvider: StubSessionProvider(token: "tok-123"),
            transport: transport
        )

        let response = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastURL, ManagedInference.draftEndpoint)
        XCTAssertEqual(transport.lastHeaders?["authorization"], "Bearer tok-123")
        XCTAssertEqual(transport.lastHeaders?["content-type"], "application/json")

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(object["system"] as? String, "You write like the user.")
        XCTAssertEqual(object["maxTokens"] as? Int, 512)
        XCTAssertEqual(object["temperature"] as? Double, 0.6)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "Draft a reply.")

        XCTAssertEqual(response.text, "Hi Marcus,")
        XCTAssertEqual(response.inputTokens, 40)
        XCTAssertEqual(response.outputTokens, 12)
    }

    func testMaps402ToManagedTrialExpiredWithServerMessage() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"trial_expired","message":"Your 14-day free trial has ended."}}"#,
            status: 402
        ))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected trial-expired error")
        } catch LLMError.managedTrialExpired(let message) {
            XCTAssertEqual(message, "Your 14-day free trial has ended.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMaps401ToManagedNotSignedIn() async {
        let sessionProvider = RecordingSessionProvider()
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"unauthenticated","message":"Sign in."}}"#,
            status: 401
        ))
        let client = ManagedInferenceClient(sessionProvider: sessionProvider, transport: transport)

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected not-signed-in error")
        } catch LLMError.managedNotSignedIn {
            let awaited1 = await sessionProvider.didInvalidate
            XCTAssertTrue(awaited1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMapsGenericServerErrorToHTTPWithMessage() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"overloaded","message":"The drafting service is temporarily overloaded."}}"#,
            status: 503
        ))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected http error")
        } catch LLMError.http(let status, let message) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(message, "The drafting service is temporarily overloaded.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Quota (item 56b)

    func testDecodesQuotaFromDraftResponse() async throws {
        let transport = FakeLLMTransport(response: json(#"""
        {
          "text": "Hi Marcus,",
          "usage": {"inputTokens": 40, "outputTokens": 12},
          "quota": {
            "unit": "drafts", "used": 12, "limit": 50, "remaining": 38,
            "resetsAt": "2025-09-01T00:00:00Z", "tokensUsed": 6000,
            "tokenLimit": 250000, "enforcement": "soft", "extraPurchased": 0
          }
        }
        """#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        let response = try await client.complete(sampleRequest())
        let quota = try XCTUnwrap(response.quota)
        XCTAssertEqual(quota.used, 12)
        XCTAssertEqual(quota.limit, 50)
        XCTAssertEqual(quota.remaining, 38)
        XCTAssertEqual(quota.enforcement, .soft)
    }

    func testDraftResponseWithoutQuotaDecodesToNil() async throws {
        let transport = FakeLLMTransport(response: json(#"{"text":"Hi","usage":{"inputTokens":1,"outputTokens":1}}"#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)
        let response = try await client.complete(sampleRequest())
        XCTAssertNil(response.quota)
        XCTAssertEqual(response.text, "Hi")
    }

    func testMaps429RateLimitedWithRetryAfterFromBody() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"rate_limited","message":"Slow down.","retryAfterSeconds":9}}"#,
            status: 429,
            headers: ["Retry-After": "30"]
        ))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)
        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected rate-limited error")
        } catch LLMError.managedRateLimited(let retryAfter) {
            // Body's retryAfterSeconds wins over the header.
            XCTAssertEqual(retryAfter, 9)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMaps429RateLimitedFallsBackToRetryAfterHeader() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"rate_limited","message":"Slow down."}}"#,
            status: 429,
            headers: ["Retry-After": "30"]
        ))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)
        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected rate-limited error")
        } catch LLMError.managedRateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 30)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMaps429QuotaExceededWithResetsAt() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"quota_exceeded","message":"Out of drafts.","resetsAt":"2025-09-08T00:00:00Z"}}"#,
            status: 429
        ))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)
        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected quota-exceeded error")
        } catch LLMError.managedQuotaExceeded(let resetsAt) {
            XCTAssertEqual(resetsAt, ManagedQuotaDate.date(from: "2025-09-08T00:00:00Z"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMaps413RequestTooLarge() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"request_too_large","message":"Transcript too big."}}"#,
            status: 413
        ))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)
        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected request-too-large error")
        } catch LLMError.managedRequestTooLarge(let message) {
            XCTAssertEqual(message, "Transcript too big.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchAccountQuotaUsesGetAndDecodesQuota() async throws {
        let transport = FakeLLMTransport(response: json(#"""
        {
          "userId": "user_123",
          "trial": {"active": true},
          "quota": {"unit":"drafts","used":5,"limit":50,"remaining":45,
                    "resetsAt":"2025-09-01T00:00:00Z","enforcement":"soft"}
        }
        """#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(token: "tok-me"), transport: transport)

        let quota = try await client.fetchAccountQuota(meEndpoint: ManagedInference.meEndpoint)

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastURL, ManagedInference.meEndpoint)
        XCTAssertEqual(transport.lastHeaders?["authorization"], "Bearer tok-me")
        XCTAssertEqual(quota?.used, 5)
        XCTAssertEqual(quota?.remaining, 45)
    }

    func testFetchAccountStatusDecodesUserIDAndQuota() async throws {
        let transport = FakeLLMTransport(response: json(#"""
        {
          "userId": " user_123 ",
          "quota": {"unit":"drafts","used":5,"limit":50,"remaining":45,
                    "resetsAt":"2025-09-01T00:00:00Z","enforcement":"soft"}
        }
        """#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        let status = try await client.fetchAccountStatus()

        XCTAssertEqual(status.userID, "user_123")
        XCTAssertEqual(status.stableAccountIdentifier, "clerk-user:user_123")
        XCTAssertEqual(status.quota?.used, 5)
    }

    func testFetchAccountQuotaReturnsNilWhenOmitted() async throws {
        let transport = FakeLLMTransport(response: json(#"{"userId":"user_123","trial":{"active":true}}"#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)
        let quota = try await client.fetchAccountQuota()
        XCTAssertNil(quota)
    }

    func testFetchAccountQuotaRejectsMalformedStatusBody() async {
        let transport = FakeLLMTransport(response: json(#"{"userId":"user_123","quota":"not-an-object"}"#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        do {
            _ = try await client.fetchAccountQuota()
            XCTFail("Expected invalid account status body")
        } catch LLMError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("Unexpected account status response shape"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStubClientReturnsStubbedQuota() async throws {
        let response = try await StubManagedInferenceClient().complete(sampleRequest())
        let quota = try XCTUnwrap(response.quota)
        XCTAssertEqual(quota.limit, 50)
        XCTAssertEqual(quota.unit, "drafts")
    }

    // MARK: - Delete account (item 73)

    func testDeleteAccountUsesDeleteAndBearerOn204() async throws {
        let transport = FakeLLMTransport(response: HTTPResponse(statusCode: 204, body: Data()))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(token: "tok-del"), transport: transport)

        try await client.deleteAccount()

        XCTAssertEqual(transport.lastMethod, "DELETE")
        XCTAssertEqual(transport.lastURL, ManagedInference.meEndpoint)
        XCTAssertEqual(transport.lastHeaders?["authorization"], "Bearer tok-del")
    }

    func testDeleteAccountMaps401ToNotSignedInAndInvalidates() async {
        let sessionProvider = RecordingSessionProvider()
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"unauthenticated","message":"Sign in."}}"#,
            status: 401
        ))
        let client = ManagedInferenceClient(sessionProvider: sessionProvider, transport: transport)

        do {
            try await client.deleteAccount()
            XCTFail("Expected not-signed-in error")
        } catch LLMError.managedNotSignedIn {
            let invalidated = await sessionProvider.didInvalidate
            XCTAssertTrue(invalidated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeleteAccountMaps502ToAccountDeletionFailed() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"account_deletion_failed","message":"We couldn't delete your account."}}"#,
            status: 502
        ))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        do {
            try await client.deleteAccount()
            XCTFail("Expected account-deletion-failed error")
        } catch LLMError.managedAccountDeletionFailed(let message) {
            XCTAssertEqual(message, "We couldn't delete your account.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeleteAccountNotSignedInSkipsTransport() async {
        let transport = FakeLLMTransport(response: HTTPResponse(statusCode: 204, body: Data()))
        let client = ManagedInferenceClient(
            sessionProvider: StubSessionProvider(error: LLMError.managedNotSignedIn),
            transport: transport
        )

        do {
            try await client.deleteAccount()
            XCTFail("Expected not-signed-in error")
        } catch LLMError.managedNotSignedIn {
            XCTAssertNil(transport.lastURL, "transport must not be called when not signed in")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchAccountStatusDecodesTrialAndSubscription() async throws {
        let transport = FakeLLMTransport(response: json(#"""
        {
          "userId": "user_9",
          "email": "marcus@example.com",
          "trial": {"startedAt":"2026-08-01T00:00:00Z","endsAt":"2026-08-15T00:00:00Z","active":true},
          "subscription": {"plan":"trial","status":"trialing","manageBillingUrl":null}
        }
        """#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        let status = try await client.fetchAccountStatus()

        XCTAssertEqual(status.email, "marcus@example.com")
        XCTAssertEqual(status.trial?.active, true)
        XCTAssertEqual(status.subscription?.plan, .trial)
        XCTAssertEqual(status.subscription?.status, .trialing)
        XCTAssertNil(status.subscription?.manageBillingURL)
        XCTAssertNil(status.quota)
    }

    func testPropagatesNotSignedInFromSessionProviderWithoutCallingTransport() async {
        let transport = FakeLLMTransport(response: json("{}"))
        let client = ManagedInferenceClient(
            sessionProvider: StubSessionProvider(error: LLMError.managedNotSignedIn),
            transport: transport
        )

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("Expected not-signed-in error")
        } catch LLMError.managedNotSignedIn {
            XCTAssertNil(transport.lastURL, "transport must not be called when not signed in")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
