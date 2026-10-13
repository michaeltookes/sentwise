import AppKit
import Foundation
import Network
import os

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "OAuthRedirect")

/// Opens a URL in the user's default browser.
protocol BrowserOpening {
    func open(_ url: URL)
}

/// Production browser opener backed by `NSWorkspace`.
struct NSWorkspaceBrowserOpener: BrowserOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Listens for the OAuth redirect and returns its query parameters.
protocol RedirectListener {
    /// Starts listening and returns the loopback redirect URI to register.
    func start() async throws -> String
    /// Waits for the browser redirect and returns its query parameters.
    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String]
    /// Stops listening and releases the port.
    func stop()
}

/// A loopback (`127.0.0.1`) HTTP listener for the installed-app PKCE redirect.
///
/// The query-parsing is factored out as a pure static function and unit-tested;
/// the socket handling itself is verified live.
final class LoopbackRedirectListener: RedirectListener {

    private let queue = DispatchQueue(label: "com.tookes.Sentwise.loopback")
    private var listener: NWListener?
    private var hasResumed = false
    private var redirectContinuation: CheckedContinuation<[String: String], Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    func start() async throws -> String {
        let listener = try NWListener(using: Self.listenerParameters())
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            func finish(_ result: Result<String, Error>) {
                guard !didResume else { return }
                didResume = true
                listener.stateUpdateHandler = nil
                continuation.resume(with: result)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        finish(.success(Self.redirectURI(forPort: port)))
                    } else {
                        finish(.failure(OAuthError.invalidResponse))
                    }
                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    static func redirectURI(forPort port: UInt16) -> String {
        "http://127.0.0.1:\(port)"
    }

    static func listenerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: .any
        )
        return parameters
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let listener = self.listener else {
                    continuation.resume(throwing: OAuthError.invalidResponse)
                    return
                }

                self.hasResumed = false
                self.redirectContinuation = continuation

                let timeoutWorkItem = DispatchWorkItem { [weak self] in
                    self?.finishRedirect(.failure(OAuthError.redirectTimedOut))
                }
                self.timeoutWorkItem = timeoutWorkItem
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection: connection)
                }
            }
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let params = Self.parseQuery(fromRequestLine: request)

            self.respond(on: connection)

            // Ignore incidental requests (e.g. favicon) that carry no result.
            guard params["code"] != nil || params["error"] != nil else { return }
            self.finishRedirect(.success(params))
        }
    }

    private func finishRedirect(_ result: Result<[String: String], Error>) {
        guard !hasResumed else { return }
        hasResumed = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        listener?.newConnectionHandler = nil

        let continuation = redirectContinuation
        redirectContinuation = nil
        continuation?.resume(with: result)
    }

    private func respond(on connection: NWConnection) {
        let body = "Sentwise is connected. You can close this window and return to the app."
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func stop() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    /// Parses query parameters from the first line of an HTTP request, e.g.
    /// `GET /?code=abc&state=xyz HTTP/1.1`.
    static func parseQuery(fromRequestLine request: String) -> [String: String] {
        let lines = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        guard let firstLine = lines.first else { return [:] }
        let fields = firstLine.split(separator: " ")
        guard fields.count >= 2 else { return [:] }
        guard let components = URLComponents(string: "http://127.0.0.1\(fields[1])") else { return [:] }
        return (components.queryItems ?? []).reduce(into: [:]) { result, item in
            result[item.name] = item.value
        }
    }
}
