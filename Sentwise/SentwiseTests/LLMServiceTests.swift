import XCTest
@testable import Sentwise

private actor RecordingQuotaReporter: ManagedQuotaReporting {
    private var accountKey: String?
    private var reportedAccountKeys: [String] = []

    init(accountKey: String?) {
        self.accountKey = accountKey
    }

    func setAccountKey(_ accountKey: String?) {
        self.accountKey = accountKey
    }

    func currentQuotaReportAccountKey() async -> String? {
        accountKey
    }

    func reportQuota(_ quota: ManagedQuota, accountKey: String) async {
        reportedAccountKeys.append(accountKey)
    }

    func accountKeys() -> [String] {
        reportedAccountKeys
    }
}

final class LLMServiceTests: XCTestCase {

    func testTestConnectionSendsMinimalRequestWithChosenModel() async throws {
        let transport = FakeLLMTransport(response: HTTPResponse(
            statusCode: 200,
            body: Data(#"{"content":[{"type":"text","text":"OK"}]}"#.utf8)
        ))
        let service = LLMService(transport: transport)

        try await service.testConnection(provider: .anthropic, apiKey: "sk-test", model: "claude-haiku-4-5-20251001")

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "claude-haiku-4-5-20251001")
        XCTAssertEqual(transport.lastHeaders?["x-api-key"], "sk-test")
    }

    func testTestConnectionRoutesOpenAICompatibleToDefaultEndpoint() async throws {
        let transport = FakeLLMTransport(response: HTTPResponse(
            statusCode: 200,
            body: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        ))
        let service = LLMService(transport: transport)

        try await service.testConnection(
            provider: .openAICompatible,
            apiKey: "sk-openai",
            model: "gpt-4o-mini",
            baseURL: nil
        )

        XCTAssertEqual(transport.lastURL?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(transport.lastHeaders?["Authorization"], "Bearer sk-openai")
        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gpt-4o-mini")
    }

    func testCompleteRoutesOpenAICompatibleThroughCustomBaseURL() async throws {
        let transport = FakeLLMTransport(response: HTTPResponse(
            statusCode: 200,
            body: Data(#"{"choices":[{"message":{"content":"Hi"}}]}"#.utf8)
        ))
        let service = LLMService(transport: transport)

        _ = try await service.complete(
            LLMRequest(messages: [LLMMessage(role: .user, content: "Hi")], model: "llama-3.1-8b"),
            provider: .openAICompatible,
            apiKey: "sk-gateway",
            baseURL: "https://openrouter.ai/api/v1"
        )

        XCTAssertEqual(transport.lastURL?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
    }

    func testTestConnectionRoutesLocalProviderToOllamaEndpointWithoutKey() async throws {
        let transport = FakeLLMTransport(response: HTTPResponse(
            statusCode: 200,
            body: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        ))
        let service = LLMService(transport: transport)

        try await service.testConnection(
            provider: .ollama,
            apiKey: "",
            model: "llama3.1",
            baseURL: nil
        )

        XCTAssertEqual(transport.lastURL?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(transport.lastHeaders?["Authorization"], "local provider omits the Authorization header")
        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "llama3.1")
    }

    func testCompleteRoutesLocalProviderThroughCustomBaseURL() async throws {
        let transport = FakeLLMTransport(response: HTTPResponse(
            statusCode: 200,
            body: Data(#"{"choices":[{"message":{"content":"Hi"}}]}"#.utf8)
        ))
        let service = LLMService(transport: transport)

        _ = try await service.complete(
            LLMRequest(messages: [LLMMessage(role: .user, content: "Hi")], model: "qwen2.5"),
            provider: .ollama,
            apiKey: "",
            baseURL: "http://localhost:1234/v1"
        )

        XCTAssertEqual(transport.lastURL?.absoluteString, "http://localhost:1234/v1/chat/completions")
        XCTAssertNil(transport.lastHeaders?["Authorization"])
    }

    func testTestConnectionSurfacesInvalidBaseURLWithoutHittingTransport() async {
        let transport = FakeLLMTransport(response: HTTPResponse(
            statusCode: 200,
            body: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        ))
        let service = LLMService(transport: transport)

        do {
            try await service.testConnection(
                provider: .openAICompatible,
                apiKey: "sk-openai",
                model: "gpt-4o-mini",
                baseURL: "https://my host/v1"
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LLMError, .invalidBaseURL("https://my host/v1"))
        }
        XCTAssertNil(transport.lastURL, "transport must not be called for an invalid base URL")
    }

    func testTestConnectionSurfacesProviderError() async {
        let transport = FakeLLMTransport(response: HTTPResponse(
            statusCode: 401,
            body: Data(#"{"error":{"message":"bad key"}}"#.utf8)
        ))
        let service = LLMService(transport: transport)

        do {
            try await service.testConnection(provider: .anthropic, apiKey: "nope", model: "claude-sonnet-4-6")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LLMError, .http(status: 401, message: "bad key"))
        }
    }

    func testManagedCompletionReportsQuotaWithRequestStartAccountKey() async throws {
        let reporter = RecordingQuotaReporter(accountKey: "acct-a")
        let transport = ManagedProviderSuspendedLLMTransport()
        let service = LLMService(
            transport: transport,
            managedSessionProvider: FixedSessionProvider(token: "tok-managed"),
            quotaReporter: reporter
        )

        let completion = Task {
            try await service.complete(
                LLMRequest(messages: [LLMMessage(role: .user, content: "Draft")], model: "claude-sonnet-4-6"),
                provider: .managed,
                apiKey: "",
                baseURL: nil
            )
        }
        await fulfillment(of: [transport.didStartRequest], timeout: 1)
        await reporter.setAccountKey("acct-b")
        transport.complete(with: .success(HTTPResponse(
            statusCode: 200,
            body: Data(#"""
            {
              "text": "Hi",
              "usage": {"inputTokens": 1, "outputTokens": 1},
              "quota": {
                "unit": "drafts", "used": 10, "limit": 50, "remaining": 40,
                "resetsAt": "2025-09-01T00:00:00Z", "enforcement": "soft"
              }
            }
            """#.utf8)
        )))

        _ = try await completion.value

        let accountKeys = await reporter.accountKeys()
        XCTAssertEqual(accountKeys, ["acct-a"])
    }
}
