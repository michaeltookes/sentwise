import Foundation

/// A minimal HTTP response used by the OAuth services.
struct HTTPResponse: Equatable {
    let statusCode: Int
    let body: Data
    /// Response headers (keys as returned by the server). Defaulted so existing
    /// call sites that don't care about headers are unaffected; the managed
    /// inference client reads `Retry-After` from here (backlog item 56b).
    let headers: [String: String]

    init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// Case-insensitive header lookup (HTTP header names are case-insensitive).
    func headerValue(_ name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}

/// Abstraction over the network so OAuth logic can be tested without live calls.
protocol HTTPTransport {
    /// Sends an `application/x-www-form-urlencoded` POST and returns the response.
    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse
}

/// `URLSession`-backed transport used in production.
struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields)

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return HTTPResponse(
            statusCode: http?.statusCode ?? -1,
            body: data,
            headers: Self.headerFields(from: http)
        )
    }

    /// Flattens an `HTTPURLResponse`'s header fields into a `[String: String]`.
    static func headerFields(from response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return headers
    }

    /// Percent-encodes fields for form submission, encoding reserved characters
    /// like `+`, `/`, and `=` that appear in OAuth codes and tokens.
    static func formEncode(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let body = fields
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}
