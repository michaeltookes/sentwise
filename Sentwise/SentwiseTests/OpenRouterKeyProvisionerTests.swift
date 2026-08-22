import XCTest
@testable import Sentwise

/// A fake `LLMHTTPTransport` returning a preset result and recording the request.
private final class FakeJSONTransport: LLMHTTPTransport, @unchecked Sendable {
    private let result: Result<HTTPResponse, Error>
    private(set) var lastURL: URL?
    private(set) var lastBody: Data?

    init(_ result: Result<HTTPResponse, Error>) {
        self.result = result
    }

    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        lastURL = url
        lastBody = body
        return try result.get()
    }
}

/// Unit tests for the OpenRouter PKCE key-provisioning flow (item 59).
final class OpenRouterKeyProvisionerTests: XCTestCase {

    func testAuthorizationURLCarriesCallbackAndChallenge() {
        let url = OpenRouterKeyProvisioner(transport: FakeJSONTransport(.success(HTTPResponse(statusCode: 200, body: Data()))))
            .authorizationURL(callbackURL: "sentwise://openrouter-callback", challenge: "CHAL")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.host, "openrouter.ai")
        XCTAssertEqual(url.path, "/auth")
        XCTAssertEqual(items.first { $0.name == "callback_url" }?.value, "sentwise://openrouter-callback")
        XCTAssertEqual(items.first { $0.name == "code_challenge" }?.value, "CHAL")
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
    }

    func testExchangeCodeForKeyReturnsKeyAndSendsVerifier() async throws {
        let transport = FakeJSONTransport(.success(
            HTTPResponse(statusCode: 200, body: Data(#"{"key":"sk-or-v1-abc"}"#.utf8))
        ))
        let key = try await OpenRouterKeyProvisioner(transport: transport)
            .exchangeCodeForKey(code: "CODE", codeVerifier: "VERIFIER")

        XCTAssertEqual(key, "sk-or-v1-abc")
        XCTAssertEqual(transport.lastURL?.absoluteString, "https://openrouter.ai/api/v1/auth/keys")
        let sent = try XCTUnwrap(transport.lastBody)
        let json = try JSONSerialization.jsonObject(with: sent) as? [String: String]
        XCTAssertEqual(json?["code"], "CODE")
        XCTAssertEqual(json?["code_verifier"], "VERIFIER")
        XCTAssertEqual(json?["code_challenge_method"], "S256")
    }

    func testExchangeSurfacesHTTPError() async {
        let transport = FakeJSONTransport(.success(
            HTTPResponse(statusCode: 400, body: Data(#"{"error":{"message":"bad code"}}"#.utf8))
        ))
        do {
            _ = try await OpenRouterKeyProvisioner(transport: transport)
                .exchangeCodeForKey(code: "CODE", codeVerifier: "VERIFIER")
            XCTFail("Expected http error")
        } catch LLMError.http(let status, let message) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(message, "bad code")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExchangeCapsRawErrorBodyFallback() async {
        // A non-JSON body (e.g. an HTML error page) must be collapsed and capped,
        // never surfaced raw.
        let html = "<html>\n<body>\n" + String(repeating: "error ", count: 100) + "\n</body>\n</html>"
        let transport = FakeJSONTransport(.success(HTTPResponse(statusCode: 502, body: Data(html.utf8))))
        do {
            _ = try await OpenRouterKeyProvisioner(transport: transport)
                .exchangeCodeForKey(code: "CODE", codeVerifier: "VERIFIER")
            XCTFail("Expected http error")
        } catch LLMError.http(let status, let message) {
            XCTAssertEqual(status, 502)
            XCTAssertLessThanOrEqual(message.count, 200)
            XCTAssertFalse(message.contains("\n"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExchangeThrowsWhenKeyMissing() async {
        let transport = FakeJSONTransport(.success(
            HTTPResponse(statusCode: 200, body: Data(#"{"user_id":"u_1"}"#.utf8))
        ))
        do {
            _ = try await OpenRouterKeyProvisioner(transport: transport)
                .exchangeCodeForKey(code: "CODE", codeVerifier: "VERIFIER")
            XCTFail("Expected invalidResponse")
        } catch LLMError.invalidResponse {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
