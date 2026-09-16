import Foundation

/// `LLMClient` adapter for any provider speaking the OpenAI
/// `/v1/chat/completions` wire format.
///
/// Parked 2026-09-16 (item 100): the BYO OpenAI-compatible provider and the local
/// (Ollama) path were removed from the UI; managed inference is the only shipped
/// path. This adapter stays compiling and unit-tested but is unreachable from the
/// UI — kept for possible future revival.
///
/// See https://platform.openai.com/docs/api-reference/chat. Auth is a
/// `Authorization: Bearer <key>` header. Because the endpoint is configurable,
/// one adapter covers OpenAI itself plus compatible gateways — OpenRouter, Groq,
/// Mistral, DeepSeek, Together, LM Studio, and Ollama's OpenAI-compat endpoint —
/// simply by pointing `baseURL` at each host.
struct OpenAICompatibleClient: LLMClient {
    let apiKey: String
    let transport: LLMHTTPTransport
    let baseURL: String?
    /// The endpoint used when `baseURL` is blank/`nil`. Defaults to OpenAI's
    /// official endpoint; the local (Ollama) provider passes its loopback one.
    let defaultEndpoint: URL
    /// Whether an API key is mandatory. Cloud providers require one (an empty key
    /// fails fast with `.missingAPIKey`); local runtimes set this to `false`, so
    /// an empty key is valid and the `Authorization` header is omitted.
    let requiresAPIKey: Bool

    /// OpenAI's official chat-completions endpoint, used when the user hasn't
    /// supplied a custom base URL.
    static let defaultEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// Ollama's local OpenAI-compatible chat-completions endpoint, used as the
    /// default for the local provider when the base-URL field is blank.
    static let ollamaDefaultEndpoint = URL(string: "http://localhost:11434/v1/chat/completions")!

    /// - Parameters:
    ///   - baseURL: a user-supplied base URL (e.g.
    ///     `https://openrouter.ai/api/v1`). Blank/`nil` falls back to
    ///     `defaultEndpoint`. See `resolveEndpoint(baseURL:defaultEndpoint:)` for
    ///     normalization.
    ///   - defaultEndpoint: the endpoint used when `baseURL` is blank.
    ///   - requiresAPIKey: whether an empty key should fail fast. Local runtimes
    ///     pass `false`.
    init(
        apiKey: String,
        transport: LLMHTTPTransport,
        baseURL: String? = nil,
        defaultEndpoint: URL = OpenAICompatibleClient.defaultEndpoint,
        requiresAPIKey: Bool = true
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
        self.defaultEndpoint = defaultEndpoint
        self.requiresAPIKey = requiresAPIKey
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        if requiresAPIKey {
            guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        }

        // Resolve (and validate) the endpoint before touching the network so a
        // bad base URL fails fast — never silently routing the user's key to a
        // different host.
        let endpoint = try Self.resolveEndpoint(baseURL: baseURL, defaultEndpoint: defaultEndpoint)

        let body = try Self.encodeBody(request)
        // Omit the Authorization header entirely when there's no key — some
        // local servers reject a bare "Bearer " — rather than sending an empty
        // credential. Cloud providers always have a key here (required above).
        var headers = ["content-type": "application/json"]
        if !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }

        let response: HTTPResponse
        do {
            response = try await transport.postJSON(endpoint, headers: headers, body: body)
        } catch {
            throw LLMError.transport(String(describing: error))
        }

        guard response.isSuccess else {
            throw LLMError.http(status: response.statusCode, message: Self.errorMessage(from: response.body))
        }
        return try Self.parse(response.body)
    }

    // MARK: - Endpoint resolution

    /// Normalizes a user-supplied base URL into a full chat-completions endpoint.
    ///
    /// - Blank/`nil` → OpenAI's official endpoint.
    /// - A base ending in `/chat/completions` is used verbatim.
    /// - Otherwise `/chat/completions` is appended (trailing slashes trimmed),
    ///   so `https://openrouter.ai/api/v1` and `http://localhost:11434/v1`
    ///   both resolve correctly.
    /// - Query parameters and fragments are preserved, with the suffix appended
    ///   to the URL path before them.
    ///
    /// Throws `LLMError.invalidBaseURL` for input that doesn't parse or whose
    /// scheme isn't `http`/`https` (e.g. an embedded space, or a scheme-less
    /// `openrouter.ai/api/v1`) rather than silently falling back to the default —
    /// which would leak the user's key to the wrong host.
    ///
    /// - Parameter defaultEndpoint: the endpoint returned for blank input.
    ///   Defaults to OpenAI's; the local provider passes its loopback endpoint.
    static func resolveEndpoint(
        baseURL: String?,
        defaultEndpoint: URL = OpenAICompatibleClient.defaultEndpoint
    ) throws -> URL {
        let trimmed = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultEndpoint }

        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            throw LLMError.invalidBaseURL(trimmed)
        }

        let suffix = "/chat/completions"
        components.path = endpointPath(appending: suffix, to: components.path)

        guard let url = components.url else {
            throw LLMError.invalidBaseURL(trimmed)
        }
        return url
    }

    private static func endpointPath(appending suffix: String, to path: String) -> String {
        var trimmedPath = path
        while trimmedPath.hasSuffix("/") { trimmedPath.removeLast() }
        guard !trimmedPath.hasSuffix(suffix) else { return trimmedPath }
        return trimmedPath.isEmpty ? suffix : trimmedPath + suffix
    }

    // MARK: - Wire format

    private static func encodeBody(_ request: LLMRequest) throws -> Data {
        // OpenAI folds the system prompt into the messages array as a leading
        // `system` role, rather than a top-level field the way Anthropic does.
        var messages: [RequestBody.Message] = []
        if let system = request.system, !system.isEmpty {
            messages.append(RequestBody.Message(role: "system", content: system))
        }
        messages.append(
            contentsOf: request.messages.map { RequestBody.Message(role: $0.role.rawValue, content: $0.content) }
        )

        let usesCompletionTokens = Self.usesMaxCompletionTokens(model: request.model)
        let body = RequestBody(
            model: request.model,
            messages: messages,
            maxTokens: usesCompletionTokens ? nil : request.maxTokens,
            maxCompletionTokens: usesCompletionTokens ? request.maxTokens : nil,
            temperature: Self.allowsSamplingParameters(model: request.model) ? request.temperature : nil
        )
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw LLMError.invalidResponse("Couldn't encode the request. (\(error))")
        }
    }

    private static func parse(_ data: Data) throws -> LLMResponse {
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw LLMError.invalidResponse("Unexpected response shape. (\(error))")
        }
        let text = decoded.choices.first?.message?.content ?? ""
        return LLMResponse(
            text: text,
            inputTokens: decoded.usage?.promptTokens,
            outputTokens: decoded.usage?.completionTokens
        )
    }

    private static func errorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data),
           let message = decoded.error?.message, !message.isEmpty {
            return message
        }
        if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            return raw
        }
        return "The provider returned an error."
    }

    // MARK: - Model quirks

    /// OpenAI's reasoning / next-generation model families reject the legacy
    /// `max_tokens` field and require `max_completion_tokens`. Compatible
    /// gateways generally accept `max_tokens`, so only these OpenAI-native
    /// families switch fields.
    static func usesMaxCompletionTokens(model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
            || normalized.hasPrefix("gpt-5")
    }

    /// The same reasoning families also reject a custom `temperature` (only the
    /// default is accepted), so it is omitted for them.
    private static func allowsSamplingParameters(model: String) -> Bool {
        !usesMaxCompletionTokens(model: model)
    }
}

// MARK: - Wire-format DTOs (file-private to keep type nesting shallow)

private struct RequestBody: Encodable {
    let model: String
    let messages: [Message]
    let maxTokens: Int?
    let maxCompletionTokens: Int?
    let temperature: Double?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case temperature
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ResponseBody: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message?

        struct Message: Decodable {
            let content: String?
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

private struct ErrorBody: Decodable {
    let error: Detail?
    struct Detail: Decodable {
        let message: String?
    }
}
