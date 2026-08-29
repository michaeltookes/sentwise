import Foundation

/// Sends JSON requests with arbitrary headers. LLM APIs need `application/json`
/// bodies and per-provider auth headers, which the form-encoded `HTTPTransport`
/// doesn't cover; this keeps the LLM layer injectable for tests without a live
/// network call.
protocol LLMHTTPTransport: Sendable {
    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse
    /// Sends an authenticated GET (e.g. the managed `/v1/me` account/quota fetch,
    /// backlog item 56b). Bodyless — auth and content-type ride in `headers`.
    func getJSON(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

extension LLMHTTPTransport {
    /// Default so POST-only adapters/doubles need not implement GET. The managed
    /// `/v1/me` path is served by `URLSessionTransport`, which overrides this; a
    /// double that reaches here surfaces the misuse instead of silently succeeding.
    func getJSON(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        throw LLMError.transport("getJSON is not supported by \(type(of: self))")
    }
}

extension URLSessionTransport: LLMHTTPTransport {
    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return HTTPResponse(
            statusCode: http?.statusCode ?? -1,
            body: data,
            headers: URLSessionTransport.headerFields(from: http)
        )
    }

    func getJSON(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return HTTPResponse(
            statusCode: http?.statusCode ?? -1,
            body: data,
            headers: URLSessionTransport.headerFields(from: http)
        )
    }
}
