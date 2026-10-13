import Network
import XCTest
@testable import Sentwise

final class LoopbackRedirectListenerTests: XCTestCase {

    func testRedirectURIIsPathlessLoopbackURI() throws {
        let redirectURI = LoopbackRedirectListener.redirectURI(forPort: 9999)
        let components = try XCTUnwrap(URLComponents(string: redirectURI))

        XCTAssertEqual(components.scheme, "http")
        XCTAssertEqual(components.host, "127.0.0.1")
        XCTAssertEqual(components.port, 9999)
        XCTAssertEqual(components.path, "")
        XCTAssertNil(components.query)
        XCTAssertFalse(redirectURI.contains("/callback"))
    }

    func testListenerParametersConfineToIPv4LoopbackWithoutPinnedEndpoint() throws {
        let parameters = LoopbackRedirectListener.listenerParameters()
        // Pinning `requiredLocalEndpoint` with port `.any` is what made the
        // listener fail with EINVAL (NWError 22) — it must stay unset.
        XCTAssertNil(parameters.requiredLocalEndpoint)
        XCTAssertEqual(parameters.requiredInterfaceType, .loopback)
        XCTAssertTrue(parameters.acceptLocalOnly)
        let ipOptions = try XCTUnwrap(parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)
        XCTAssertEqual(ipOptions.version, .v4)
    }

    func testParsesCodeAndStateFromRequestLine() {
        let request = "GET /?code=abc123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let params = LoopbackRedirectListener.parseQuery(fromRequestLine: request)
        XCTAssertEqual(params["code"], "abc123")
        XCTAssertEqual(params["state"], "xyz")
    }

    func testParsesErrorRedirect() {
        let request = "GET /?error=access_denied&state=xyz HTTP/1.1\r\n\r\n"
        let params = LoopbackRedirectListener.parseQuery(fromRequestLine: request)
        XCTAssertEqual(params["error"], "access_denied")
    }

    func testReturnsEmptyForMalformedRequest() {
        XCTAssertTrue(LoopbackRedirectListener.parseQuery(fromRequestLine: "").isEmpty)
        XCTAssertTrue(LoopbackRedirectListener.parseQuery(fromRequestLine: "garbage").isEmpty)
    }

    func testPathWithoutQueryYieldsNoParams() {
        let request = "GET /favicon.ico HTTP/1.1\r\n\r\n"
        XCTAssertTrue(LoopbackRedirectListener.parseQuery(fromRequestLine: request).isEmpty)
    }

    /// Regression for the parked item-3 bug (item 104): starting the listener
    /// used to fail with `NWError` POSIX 22 (EINVAL). This drives a real socket
    /// on 127.0.0.1 end to end — no browser, no network beyond loopback.
    func testListenerStartsAndCapturesARealLoopbackRedirect() async throws {
        let listener = LoopbackRedirectListener()
        let redirectURI = try await listener.start()
        defer { listener.stop() }

        let components = try XCTUnwrap(URLComponents(string: redirectURI))
        XCTAssertEqual(components.host, "127.0.0.1")
        let port = try XCTUnwrap(components.port)
        XCTAssertGreaterThan(port, 0)

        async let params = listener.waitForRedirect(timeout: 10)
        let url = try XCTUnwrap(URL(string: "\(redirectURI)/?code=live-code&state=live-state"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let session = URLSession(configuration: .ephemeral)
        let (body, response) = try await session.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(bytes: body, encoding: .utf8)?.contains("Sentwise") == true)
        let captured = try await params
        XCTAssertEqual(captured["code"], "live-code")
        XCTAssertEqual(captured["state"], "live-state")
    }

    func testRedirectArrivingBeforeWaitIsDeliveredToTheLaterWaiter() async throws {
        let listener = LoopbackRedirectListener()
        let redirectURI = try await listener.start()
        defer { listener.stop() }

        let url = try XCTUnwrap(URL(string: "\(redirectURI)/?code=early&state=s"))
        _ = try await URLSession(configuration: .ephemeral).data(from: url)

        let params = try await listener.waitForRedirect(timeout: 5)
        XCTAssertEqual(params["code"], "early")
    }

    func testStopReleasesThePortSoASecondListenerCanStart() async throws {
        let first = LoopbackRedirectListener()
        _ = try await first.start()
        first.stop()

        let second = LoopbackRedirectListener()
        let redirectURI = try await second.start()
        defer { second.stop() }
        XCTAssertTrue(redirectURI.hasPrefix("http://127.0.0.1:"))
    }

    func testWaitForRedirectHonorsTaskCancellation() async throws {
        let listener = LoopbackRedirectListener()
        _ = try await listener.start()
        defer { listener.stop() }

        let wait = Task { try await listener.waitForRedirect(timeout: 30) }
        try await Task.sleep(nanoseconds: 50_000_000)
        wait.cancel()
        do {
            _ = try await wait.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testWaitForRedirectTimesOutWhenNoRequestArrives() async throws {
        let listener = LoopbackRedirectListener()
        _ = try await listener.start()
        defer { listener.stop() }

        await assertThrows(
            try await listener.waitForRedirect(timeout: 0.01),
            OAuthError.redirectTimedOut
        )
    }

    private func assertThrows<E: Error & Equatable>(
        _ expression: @autoclosure () async throws -> some Any,
        _ expected: E,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }
}
