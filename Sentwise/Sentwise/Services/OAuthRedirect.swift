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
/// the socket handling is covered by a real-loopback unit test
/// (`LoopbackRedirectListenerTests`).
///
/// **NWError 22 fix (item 104):** the parked item-3 version pinned the listener
/// to `127.0.0.1` through `NWParameters.requiredLocalEndpoint` with port `.any`,
/// which `NWListener` rejects at start with POSIX `EINVAL` (22). The listener
/// now asks for an ephemeral port via `NWListener(using:on: .any)` and confines
/// itself to IPv4 on the loopback interface with `requiredInterfaceType` and
/// the IP protocol version instead, so it is never reachable from the network.
final class LoopbackRedirectListener: RedirectListener {

    private let queue = DispatchQueue(label: "com.tookes.Sentwise.loopback")
    private var listener: NWListener?
    private var hasResumed = false
    /// A result that settled before `waitForRedirect` registered (a very fast
    /// browser redirect, or a cancel/stop); handed to the waiter on arrival.
    private var pendingResult: Result<[String: String], Error>?
    private var redirectContinuation: CheckedContinuation<[String: String], Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var receivingConnections: [ObjectIdentifier: NWConnection] = [:]
    private static let maximumRequestLineLength = 8192

    func start() async throws -> String {
        let listener = try NWListener(using: Self.listenerParameters(), on: .any)
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
                    if let port = listener.port?.rawValue, port > 0 {
                        finish(.success(Self.redirectURI(forPort: port)))
                    } else {
                        finish(.failure(OAuthError.invalidResponse))
                    }
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CancellationError()))
                default:
                    break
                }
            }
            // Accept connections from the start: a redirect that lands before
            // `waitForRedirect` registers is kept as `pendingResult`.
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.start(queue: queue)
        }
    }

    static func redirectURI(forPort port: UInt16) -> String {
        "http://127.0.0.1:\(port)"
    }

    /// TCP over IPv4, restricted to the loopback interface. No local endpoint
    /// is pinned (that is what produced EINVAL); the port comes from `on: .any`.
    static func listenerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        return parameters
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self, self.listener != nil || self.pendingResult != nil else {
                        continuation.resume(throwing: OAuthError.invalidResponse)
                        return
                    }
                    if let pending = self.pendingResult {
                        self.pendingResult = nil
                        self.hasResumed = true
                        continuation.resume(with: pending)
                        return
                    }
                    guard !self.hasResumed else {
                        continuation.resume(throwing: OAuthError.invalidResponse)
                        return
                    }
                    self.redirectContinuation = continuation

                    let timeoutWorkItem = DispatchWorkItem { [weak self] in
                        self?.finishRedirect(.failure(OAuthError.redirectTimedOut))
                    }
                    self.timeoutWorkItem = timeoutWorkItem
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
                }
            }
        } onCancel: {
            queue.async { [weak self] in
                self?.finishRedirect(.failure(CancellationError()))
            }
        }
    }

    private func handle(connection: NWConnection) {
        receivingConnections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receiveRequestLine(on: connection, buffered: Data())
    }

    private func receiveRequestLine(on connection: NWConnection, buffered: Data) {
        let remaining = Self.maximumRequestLineLength - buffered.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffered
            if let data { buffer.append(data) }
            // TCP can split anywhere, including between CR and LF or inside
            // a percent-encoded query value. Decode only a complete line.
            guard let terminator = buffer.range(of: Data([13, 10])) else {
                if error != nil || isComplete || buffer.count >= Self.maximumRequestLineLength {
                    self.receivingConnections.removeValue(forKey: ObjectIdentifier(connection))
                    connection.cancel()
                } else {
                    self.receiveRequestLine(on: connection, buffered: buffer)
                }
                return
            }
            self.receivingConnections.removeValue(forKey: ObjectIdentifier(connection))
            let request = String(data: buffer[..<terminator.lowerBound], encoding: .utf8) ?? ""
            let params = Self.parseQuery(fromRequestLine: request)

            self.respond(on: connection)

            // Ignore incidental requests (e.g. favicon) that carry no result.
            guard params["code"] != nil || params["error"] != nil else { return }
            self.finishRedirect(.success(params))
        }
    }

    private func finishRedirect(_ result: Result<[String: String], Error>) {
        guard !hasResumed else { return }
        guard redirectContinuation != nil else {
            // No waiter yet: keep the first result for when one registers.
            if pendingResult == nil { pendingResult = result }
            return
        }
        hasResumed = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        listener?.newConnectionHandler = nil

        let continuation = redirectContinuation
        redirectContinuation = nil
        continuation?.resume(with: result)
    }

    private func respond(on connection: NWConnection) {
        let body = "Google sign-in finished. You can close this tab and return to Sentwise."
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
        queue.async { [weak self] in
            guard let self else { return }
            self.finishRedirect(.failure(CancellationError()))
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            for connection in self.receivingConnections.values { connection.cancel() }
            self.receivingConnections.removeAll()
        }
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
