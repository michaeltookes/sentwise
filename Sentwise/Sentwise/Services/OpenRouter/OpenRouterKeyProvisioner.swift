import Foundation

/// OpenRouter's PKCE key-provisioning flow (item 59): the featured one-click BYO
/// path. The app sends the user to `openrouter.ai/auth` with a `code_challenge`;
/// OpenRouter redirects back to the app's custom scheme with a `code`, which the
/// app exchanges for a real API key at `/api/v1/auth/keys`. No manual copy/paste
/// and no OpenRouter dashboard visit. The resulting key is stored in an
/// OpenRouter-scoped slot for the OpenAI-compatible provider.
///
/// Stateless and injectable (like the LLM adapters) so the exchange is unit-tested
/// against a fake transport.
struct OpenRouterKeyProvisioner {
    let transport: LLMHTTPTransport

    /// The user-facing authorization page.
    static let authURL = URL(string: "https://openrouter.ai/auth")!
    /// The PKCE code-exchange endpoint.
    static let keysEndpoint = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    /// The OpenAI-compatible base URL the provisioned key is stored against.
    static let apiBaseURL = "https://openrouter.ai/api/v1"

    init(transport: LLMHTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Builds the authorization URL to open in the browser.
    func authorizationURL(callbackURL: String, challenge: String) -> URL {
        var components = URLComponents(url: Self.authURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url ?? Self.authURL
    }

    /// Exchanges the redirect `code` (plus the stored PKCE verifier) for an API
    /// key. Throws `LLMError` on transport/HTTP/parse failure so the UI reuses the
    /// existing LLM error copy.
    func exchangeCodeForKey(code: String, codeVerifier: String) async throws -> String {
        let payload: [String: String] = [
            "code": code,
            "code_verifier": codeVerifier,
            "code_challenge_method": "S256"
        ]
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw LLMError.invalidResponse("Couldn't encode the OpenRouter exchange request. (\(error))")
        }

        let response: HTTPResponse
        do {
            response = try await transport.postJSON(
                Self.keysEndpoint,
                headers: ["content-type": "application/json"],
                body: body
            )
        } catch {
            throw LLMError.transport(String(describing: error))
        }

        guard response.isSuccess else {
            throw LLMError.http(status: response.statusCode, message: Self.errorMessage(from: response.body))
        }
        guard let key = Self.decodeKey(response.body), !key.isEmpty else {
            throw LLMError.invalidResponse("OpenRouter didn't return a key.")
        }
        return key
    }

    // MARK: - Wire format

    private static func decodeKey(_ data: Data) -> String? {
        (try? JSONDecoder().decode(KeyEnvelope.self, from: data))?.key
    }

    private static func errorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            if let message = decoded.error?.message, !message.isEmpty { return message }
            if let message = decoded.message, !message.isEmpty { return message }
        }
        // Fallback: the body may be an HTML error page, so never surface it raw.
        // Collapse to a single line and cap the length.
        if let raw = String(data: data, encoding: .utf8) {
            let collapsed = raw.split(whereSeparator: \.isNewline)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !collapsed.isEmpty { return String(collapsed.prefix(200)) }
        }
        return "OpenRouter returned an error."
    }

    private struct KeyEnvelope: Decodable {
        let key: String?
    }

    private struct ErrorEnvelope: Decodable {
        let message: String?
        let error: Detail?
        struct Detail: Decodable { let message: String? }
    }
}
