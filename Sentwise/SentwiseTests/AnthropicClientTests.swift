import XCTest
@testable import Sentwise

final class AnthropicClientTests: XCTestCase {

    private func client(_ response: HTTPResponse, key: String = "sk-test") -> (AnthropicClient, FakeLLMTransport) {
        let transport = FakeLLMTransport(response: response)
        return (AnthropicClient(apiKey: key, transport: transport), transport)
    }

    private func json(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(string.utf8))
    }

    private func sampleRequest() -> LLMRequest {
        LLMRequest(
            system: "You are helpful.",
            messages: [LLMMessage(role: .user, content: "Hi")],
            model: "claude-sonnet-4-6",
            maxTokens: 32,
            temperature: 0.5
        )
    }

    func testEncodesRequestBodyAndAuthHeaders() async throws {
        let (client, transport) = client(json(#"{"content":[{"type":"text","text":"Hello"}]}"#))

        _ = try await client.complete(sampleRequest())

        XCTAssertEqual(transport.lastURL?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(transport.lastHeaders?["x-api-key"], "sk-test")
        XCTAssertEqual(transport.lastHeaders?["anthropic-version"], "2023-06-01")
        XCTAssertEqual(transport.lastHeaders?["content-type"], "application/json")

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(object["max_tokens"] as? Int, 32)
        XCTAssertEqual(object["temperature"] as? Double, 0.5)
        XCTAssertEqual(object["system"] as? String, "You are helpful.")
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "Hi")
    }

    func testOmitsTemperatureForModelsThatRejectSamplingParameters() async throws {
        let (client, transport) = client(json(#"{"content":[{"type":"text","text":"Hello"}]}"#))
        let models = [
            "claude-sonnet-5",
            "claude-sonnet-5-20260707",
            "claude-opus-4-7",
            "claude-opus-4-7-20260707",
            "claude-opus-4-8",
            "claude-opus-4-8-20260707",
            "claude-opus-4-10",
            "claude-opus-5",
            "claude-haiku-5"
        ]

        for model in models {
            let request = LLMRequest(
                messages: [LLMMessage(role: .user, content: "Hi")],
                model: model,
                maxTokens: 32,
                temperature: 0
            )

            _ = try await client.complete(request)

            let body = try XCTUnwrap(transport.lastBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertNil(object["temperature"], "expected \(model) to omit temperature")
        }
    }

    func testKeepsTemperatureForOpusFourModelsBeforeFourSeven() async throws {
        let (client, transport) = client(json(#"{"content":[{"type":"text","text":"Hello"}]}"#))
        let models = [
            "claude-opus-4-6",
            "claude-opus-4-6-20260707"
        ]

        for model in models {
            let request = LLMRequest(
                messages: [LLMMessage(role: .user, content: "Hi")],
                model: model,
                maxTokens: 32,
                temperature: 0.5
            )

            _ = try await client.complete(request)

            let body = try XCTUnwrap(transport.lastBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["temperature"] as? Double, 0.5, "expected \(model) to keep temperature")
        }
    }

    func testParsesTextAndUsage() async throws {
        let (client, _) = client(json(#"""
        {"content":[{"type":"text","text":"Hello "},{"type":"text","text":"there"}],
         "usage":{"input_tokens":12,"output_tokens":3}}
        """#))

        let response = try await client.complete(sampleRequest())

        XCTAssertEqual(response.text, "Hello there")
        XCTAssertEqual(response.inputTokens, 12)
        XCTAssertEqual(response.outputTokens, 3)
    }

    func testMissingKeyThrowsBeforeCallingTransport() async {
        let transport = FakeLLMTransport(response: json("{}"))
        let client = AnthropicClient(apiKey: "", transport: transport)

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LLMError, .missingAPIKey)
        }
        XCTAssertNil(transport.lastURL, "transport must not be called without a key")
    }

    func testNonSuccessStatusSurfacesParsedErrorMessage() async {
        let (client, _) = client(
            json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401)
        )

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LLMError, .http(status: 401, message: "invalid x-api-key"))
        }
    }

    func testTransportFailureMapsToTransportError() async {
        let transport = FakeLLMTransport(error: URLError(.notConnectedToInternet))
        let client = AnthropicClient(apiKey: "sk-test", transport: transport)

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected an error")
        } catch {
            guard case .transport = error as? LLMError else {
                return XCTFail("expected .transport, got \(error)")
            }
        }
    }

    func testUnparseableSuccessBodySurfacesInvalidResponse() async {
        let (client, _) = client(json("not json", status: 200))

        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected an error")
        } catch {
            guard case .invalidResponse = error as? LLMError else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }
}

/// A fake `LLMHTTPTransport` returning a canned response (or error) and
/// recording the request for assertions.
final class FakeLLMTransport: LLMHTTPTransport, @unchecked Sendable {
    private let response: HTTPResponse?
    private let error: Error?
    private(set) var lastURL: URL?
    private(set) var lastHeaders: [String: String]?
    private(set) var lastBody: Data?
    /// The HTTP method of the last request ("POST" / "GET"), for tests that
    /// exercise the `/v1/me` GET path (backlog item 56b).
    private(set) var lastMethod: String?

    init(response: HTTPResponse) {
        self.response = response
        self.error = nil
    }

    init(error: Error) {
        self.response = nil
        self.error = error
    }

    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        lastMethod = "POST"
        lastURL = url
        lastHeaders = headers
        lastBody = body
        if let error { throw error }
        return response ?? HTTPResponse(statusCode: -1, body: Data())
    }

    func getJSON(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        lastMethod = "GET"
        lastURL = url
        lastHeaders = headers
        lastBody = nil
        if let error { throw error }
        return response ?? HTTPResponse(statusCode: -1, body: Data())
    }

    func deleteJSON(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        lastMethod = "DELETE"
        lastURL = url
        lastHeaders = headers
        lastBody = nil
        if let error { throw error }
        return response ?? HTTPResponse(statusCode: -1, body: Data())
    }
}
