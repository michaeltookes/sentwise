import SentwiseMail
import XCTest
@testable import Sentwise

/// A refresh made obsolete by a re-authorization ends "superseded", never as
/// an auth failure, so inbox watching keeps going on the new grant (item 104).
@MainActor
final class GoogleSignInSupersededRefreshTests: XCTestCase {

    private let state = "FIXED-STATE"

    func testStaleInvalidGrantAfterReauthorizationDoesNotPauseTheWatcher() async throws {
        let secrets = InMemorySecretStore()
        let recorder = FetchRecordingMailProvider()
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: recorder,
            llm: FakeLLMProvider(result: .success(()))
        )
        let store = GmailAuthStore(secrets: secrets)
        try store.saveToken(OAuthToken(
            accessToken: "stale-at", refreshToken: "old-rt", expiresAt: .distantPast,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        ), for: "me@gmail.com")
        let exchange = """
        {"access_token":"new-at","refresh_token":"new-rt","expires_in":3600,"token_type":"Bearer",\
        "scope":"https://mail.google.com/ openid","id_token":"\(GmailAuthCoordinatorTests.idToken(email: "me@gmail.com"))"}
        """
        let transport = GatedRefreshTransport(otherResponse: HTTPResponse(statusCode: 200, body: Data(exchange.utf8)))
        let coordinator = GmailAuthCoordinator(
            client: OAuthProviderConfiguration.google(clientID: "1234-abc.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": self.state]) },
            browser: SpyBrowser(),
            makeState: { self.state }
        )
        appState.googleMailAuth.install(coordinator)
        appState.watchStatus = .watching

        // A poll's fetch needs a refresh of the old grant, which hangs...
        let credentials = GoogleMailCredential.credentials(email: "me@gmail.com")
        let poll = Task { () -> Error? in
            do {
                _ = try await appState.mailProvider.fetchRecentMessages(credentials, mailbox: .inbox, limit: 10)
                return nil
            } catch {
                return error
            }
        }
        await fulfillment(of: [transport.didStartRefresh], timeout: 2)

        // ...the user signs in with Google again, then the old refresh fails with invalid_grant.
        _ = try await coordinator.authorize(loginHint: "me@gmail.com")
        transport.completeRefresh(HTTPResponse(statusCode: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))

        if let error = await poll.value {
            appState.handlePollFetchFailure(error)
            XCTFail("the superseded refresh surfaced as \(error)")
        }
        XCTAssertEqual(appState.watchStatus, .watching, "a stale invalid_grant never pauses the watcher")
        XCTAssertEqual(recorder.fetchCredentials.last?.authentication, .xoauth2(accessToken: "new-at"),
                       "the poll is served with the new grant's token")

        // The next poll goes straight to the new token, no further refresh.
        _ = try await appState.mailProvider.fetchRecentMessages(credentials, mailbox: .inbox, limit: 10)
        XCTAssertEqual(recorder.fetchCredentials.last?.authentication, .xoauth2(accessToken: "new-at"))
        XCTAssertEqual(transport.refreshCount, 1)
    }
}

/// Records the credentials of every fetch.
final class FetchRecordingMailProvider: MailProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MailAccountCredentials] = []

    var fetchCredentials: [MailAccountCredentials] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, limit: Int
    ) async throws -> [MailMessage] {
        lock.lock(); recorded.append(credentials); lock.unlock()
        return []
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, uid: UInt32, expectedUIDValidity: UInt32?
    ) async throws -> Data { Data() }

    func appendMessage(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, rfc822: Data, flags: [MailFlag]
    ) async throws {}
}
