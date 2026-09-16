import Foundation

/// `LLMClient` adapter for Anthropic's Messages API.
///
/// Parked 2026-09-16 (item 100): the BYO Anthropic-direct provider was removed from
/// the UI; managed inference is the only shipped path. This adapter stays compiling
/// and unit-tested but is unreachable from the UI — kept for possible future revival.
///
/// See https://docs.anthropic.com/en/api/messages. Auth is the `x-api-key`
/// header plus a pinned `anthropic-version`.
struct AnthropicClient: LLMClient {
    let apiKey: String
    let transport: LLMHTTPTransport
    let endpoint: URL

    private static let apiVersion = "2023-06-01"

    init(
        apiKey: String,
        transport: LLMHTTPTransport,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.endpoint = endpoint
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        let body = try Self.encodeBody(request)
        let headers = [
            "x-api-key": apiKey,
            "anthropic-version": Self.apiVersion,
            "content-type": "application/json"
        ]

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

    // MARK: - Wire format

    private static func encodeBody(_ request: LLMRequest) throws -> Data {
        let body = RequestBody(
            model: request.model,
            maxTokens: request.maxTokens,
            temperature: Self.allowsSamplingParameters(model: request.model) ? request.temperature : nil,
            system: request.system,
            messages: request.messages.map { RequestBody.Message(role: $0.role.rawValue, content: $0.content) }
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
        let text = decoded.content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined()
        return LLMResponse(
            text: text,
            inputTokens: decoded.usage?.inputTokens,
            outputTokens: decoded.usage?.outputTokens
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

    private static func allowsSamplingParameters(model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !rejectsSamplingParameters(model: normalized)
    }

    private static func rejectsSamplingParameters(model: String) -> Bool {
        model.hasPrefix("claude-sonnet-5")
            || model.hasPrefix("claude-opus-5")
            || model.hasPrefix("claude-haiku-5")
            || isClaudeOpus47OrLater(model)
    }

    private static func isClaudeOpus47OrLater(_ model: String) -> Bool {
        let prefix = "claude-opus-4-"
        guard model.hasPrefix(prefix) else { return false }

        let minorText = model.dropFirst(prefix.count).prefix { $0.isNumber }
        guard let minor = Int(minorText) else { return false }
        return minor >= 7
    }
}

// MARK: - Wire-format DTOs (file-private to keep type nesting shallow)

private struct RequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let temperature: Double?
    let system: String?
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case temperature
        case system
        case messages
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ResponseBody: Decodable {
    let content: [Block]
    let usage: Usage?

    struct Block: Decodable {
        let type: String
        let text: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

private struct ErrorBody: Decodable {
    let error: Detail?
    struct Detail: Decodable {
        let message: String?
    }
}
