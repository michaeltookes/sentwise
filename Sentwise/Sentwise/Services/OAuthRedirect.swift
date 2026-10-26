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
    private static let appRootURL = "\(SentwiseURLCallback.scheme)://"

    static let successPageHTML = finishPageHTML(
        title: "Signed in with Google",
        cardClass: "card",
        badge: """
        <svg viewBox="0 0 24 24" fill="none" stroke="#1f9d57" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>
        """,
        heading: "Signed in with Google",
        message: "Sentwise is connecting your mailbox. Return to the app to continue."
    )

    static let failurePageHTML = finishPageHTML(
        title: "Google sign-in didn't finish",
        cardClass: "card fail",
        badge: """
        <svg viewBox="0 0 24 24" fill="none" stroke="#d64545" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 6 6 18M6 6l12 12"/></svg>
        """,
        heading: "Google sign-in didn't finish",
        message: "Sentwise did not receive access. Return to the app and try again."
    )

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

            self.respond(on: connection, for: params)

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

    private func respond(on connection: NWConnection, for params: [String: String]) {
        connection.send(content: Self.httpResponse(for: params), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func httpResponse(for params: [String: String]) -> Data {
        let body = params["code"] == nil ? failurePageHTML : successPageHTML
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r

        """
        return Data((headers + body).utf8)
    }

    private static func finishPageHTML(
        title: String,
        cardClass: String,
        badge: String,
        heading: String,
        message: String
    ) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex">
        <title>\(title)</title>
        <style>
          :root { color-scheme: light dark; --fg:#0b0c0f; --muted:#5b6472; --bg:#f6f7f9; --card:#fff; --brand:#2f6fed; --ok:#1f9d57; --border:#e6e8ec; }
          @media (prefers-color-scheme: dark) {
            :root { --fg:#f3f4f6; --muted:#9aa4b2; --bg:#0c0e12; --card:#14171d; --brand:#5b8dff; --ok:#3fbf77; --border:#232833; }
          }
          * { box-sizing: border-box; }
          body { margin:0; min-height:100vh; display:grid; place-items:center; padding:1.5rem;
                 background:var(--bg); color:var(--fg);
                 font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }
          .card { width:100%; max-width:30rem; background:var(--card); border:1px solid var(--border);
                  border-radius:16px; padding:2.75rem 2.25rem; text-align:center;
                  box-shadow:0 1px 3px rgba(0,0,0,.06),0 8px 30px rgba(0,0,0,.06); }
          .badge { width:64px; height:64px; margin:0 auto 1.25rem; border-radius:50%;
                   display:grid; place-items:center; background:color-mix(in srgb,var(--ok) 15%,transparent); }
          .badge svg { width:34px; height:34px; }
          h1 { font-size:1.6rem; font-weight:650; margin:0 0 .5rem; letter-spacing:-.01em; }
          p { margin:.35rem 0; color:var(--muted); }
          .sub { font-size:1.02rem; }
          .hint { font-size:.85rem; margin-top:1.25rem; }
          .btn { display:inline-block; margin-top:1.5rem; padding:.7rem 1.4rem; border-radius:10px;
                 background:var(--brand); color:#fff; text-decoration:none; font-weight:600; }
          .fail .badge { background:color-mix(in srgb,#d64545 15%,transparent); }
        </style>
        </head>
        <body>
        <main class="\(cardClass)">
          <div class="badge">\(badge)</div>
          <h1>\(heading)</h1>
          <p class="sub">\(message)</p>
          <a class="btn" href="\(appRootURL)">Return to Sentwise</a>
          <p class="hint">You can close this tab.</p>
        </main>
        </body>
        </html>
        """
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
