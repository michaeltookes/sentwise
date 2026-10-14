import SentwiseMail
import XCTest
@testable import Sentwise

/// A mail session's late XOAUTH2 rejection of a token whose grant was replaced
/// by a re-authorization while the session was out is not an auth failure for
/// the new grant: it is retried, and the mailbox stays watched (item 104).
@MainActor
final class GoogleSignInSupersededMailOperationTests: XCTestCase {

    private let state = "FIXED-STATE"
    private let email = "me@gmail.com"

    private struct Harness {
        let appState: AppState
        let coordinator: GmailAuthCoordinator
        let base: GatedAuthRejectingMailProvider
    }

    private func makeHarness() throws -> Harness {
        let secrets = InMemorySecretStore()
        let base = GatedAuthRejectingMailProvider()
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: base,
            llm: FakeLLMProvider(result: .success(()))
        )
        let store = GmailAuthStore(secrets: secrets)
        try store.saveToken(OAuthToken(
            accessToken: "old-at", refreshToken: "old-rt", expiresAt: .distantFuture,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        ), for: email)
        let exchange = """
        {"access_token":"new-at","refresh_token":"new-rt","expires_in":3600,"token_type":"Bearer",\
        "scope":"https://mail.google.com/ openid","id_token":"\(GmailAuthCoordinatorTests.idToken(email: email))"}
        """
        let coordinator = GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: "1234-abc.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: FakeTransport(
                response: HTTPResponse(statusCode: 200, body: Data(exchange.utf8))
            )),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": self.state]) },
            browser: SpyBrowser(),
            makeState: { self.state }
        )
        appState.googleMailAuth.install(coordinator)
        appState.watchStatus = .watching
        return Harness(appState: appState, coordinator: coordinator, base: base)
    }

    private func startPoll(_ harness: Harness) -> Task<Error?, Never> {
        let credentials = GoogleMailCredential.credentials(email: email)
        let appState = harness.appState
        return Task { () -> Error? in
            do {
                _ = try await appState.mailProvider.fetchRecentMessages(credentials, mailbox: .inbox, limit: 10)
                return nil
            } catch {
                return error
            }
        }
    }

    func testLateAuthFailureFromSupersededGrantDoesNotPauseTheMailbox() async throws {
        let harness = try makeHarness()

        // A poll is out on the old grant's token (generation N)...
        let poll = startPoll(harness)
        await fulfillment(of: [harness.base.didStartFetch], timeout: 2)
        XCTAssertEqual(harness.base.lastCredentials?.authentication, .xoauth2(accessToken: "old-at"))

        // ...the user signs in with Google again (generation N+1), then Gmail
        // rejects the old token.
        _ = try await harness.coordinator.authorize(loginHint: email)
        harness.base.rejectFetch()

        let pollError = await poll.value
        let error = try XCTUnwrap(pollError)
        guard case .connectionFailed = error as? MailError else {
            return XCTFail("a superseded grant's rejection surfaced as \(error)")
        }
        XCTAssertEqual(ResilienceClassifier.classify(error), .transient)
        harness.appState.handlePollFetchFailure(error)
        XCTAssertEqual(harness.appState.watchStatus, .watching, "the reauthorized mailbox is not paused")
    }

    func testAuthFailureOnTheCurrentGrantStillReportsAuthentication() async throws {
        let harness = try makeHarness()

        let poll = startPoll(harness)
        await fulfillment(of: [harness.base.didStartFetch], timeout: 2)
        harness.base.rejectFetch()

        let pollError = await poll.value
        let error = try XCTUnwrap(pollError)
        guard case .authenticationFailed(let detail) = error as? MailError else {
            return XCTFail("expected an authentication failure, got \(error)")
        }
        XCTAssertTrue(GoogleMailCredential.isGoogleSignInFailureDetail(detail), detail)
        XCTAssertEqual(ResilienceClassifier.classify(error), .authentication)
    }
}

/// A mail provider whose fetch waits until the test rejects it with an
/// authentication failure, recording the credentials it was called with.
final class GatedAuthRejectingMailProvider: MailProvider, @unchecked Sendable {
    let didStartFetch = XCTestExpectation(description: "fetch started")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[MailMessage], Error>?
    private var credentials: MailAccountCredentials?

    var lastCredentials: MailAccountCredentials? {
        lock.lock(); defer { lock.unlock() }
        return credentials
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, limit: Int
    ) async throws -> [MailMessage] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.credentials = credentials
            self.continuation = continuation
            lock.unlock()
            didStartFetch.fulfill()
        }
    }

    func rejectFetch() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: MailError.authenticationFailed("535 5.7.8 Invalid credentials"))
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, uid: UInt32, expectedUIDValidity: UInt32?
    ) async throws -> Data { Data() }

    func appendMessage(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, rfc822: Data, flags: [MailFlag]
    ) async throws {}
}
