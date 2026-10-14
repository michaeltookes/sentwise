import XCTest
@testable import Sentwise

/// Abandoning a Google sign-in during the code exchange (item 6i (b)):
/// `URLSession` reports the canceled request as `URLError(.cancelled)`, which
/// must end the flow quietly instead of as a failed sign-in.
@MainActor
final class GoogleSignInCancellationTests: XCTestCase {
    private func makeCoordinator(transport: HTTPTransport) -> GmailAuthCoordinator {
        GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: "client.apps.googleusercontent.com"),
            store: GmailAuthStore(secrets: InMemorySecretStore()),
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:9999", params: ["code": "code", "state": "state"]) },
            browser: SpyBrowser(),
            makeState: { "state" }
        )
    }

    func testCanceledCodeExchangeEndsIdleAsCancellation() async {
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data()))
        transport.error = URLError(.cancelled)
        let coordinator = makeCoordinator(transport: transport)

        do {
            _ = try await coordinator.authorize()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testAbandonedServiceSignInDuringExchangeShowsNoFailure() async {
        let transport = CancellingExchangeTransport()
        let service = GoogleMailAuthService(coordinator: makeCoordinator(transport: transport))
        transport.onExchange = { service.cancelSignIn() }

        do {
            _ = try await service.signIn()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(service.phase, .idle)
    }

    func testOtherTransportErrorsStillFail() async {
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data()))
        transport.error = URLError(.notConnectedToInternet)
        let coordinator = makeCoordinator(transport: transport)

        do {
            _ = try await coordinator.authorize()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        guard case .failed = coordinator.phase else { return XCTFail("phase \(coordinator.phase)") }
    }
}

/// Mimics `URLSession`: cancels the flow mid-request, then throws
/// `URLError(.cancelled)` (never `CancellationError`).
private final class CancellingExchangeTransport: HTTPTransport, @unchecked Sendable {
    var onExchange: (@MainActor () -> Void)?

    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        if let onExchange { await onExchange() }
        throw URLError(.cancelled)
    }
}
