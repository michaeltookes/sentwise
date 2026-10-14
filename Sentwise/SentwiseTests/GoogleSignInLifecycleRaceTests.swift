import SentwiseMail
import XCTest
@testable import Sentwise

/// Lifecycle races around "Sign in with Google" (item 104): a refresh made
/// obsolete by switching the mailbox to an app password, and a sign-in result
/// that comes back to a different add-account form session.
@MainActor
final class GoogleSignInLifecycleRaceTests: XCTestCase {

    private let state = "FIXED-STATE"
    private let email = "me@gmail.com"

    func testSwitchToAppPasswordDuringRefreshKeepsTheMailboxConnected() async throws {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        let exchange = """
        {"access_token":"fresh-at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer",\
        "scope":"https://mail.google.com/ openid","id_token":"\(GmailAuthCoordinatorTests.idToken(email: email))"}
        """
        let transport = GatedRefreshTransport(otherResponse: HTTPResponse(statusCode: 200, body: Data(exchange.utf8)))
        let store = GmailAuthStore(secrets: secrets)
        appState.googleMailAuth.install(GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: "1234-abc.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": self.state]) },
            browser: SpyBrowser(),
            makeState: { self.state }
        ))

        // A watched Google mailbox whose access token has expired...
        let connected = await appState.connectWithGoogle()
        XCTAssertTrue(connected)
        XCTAssertTrue(appState.activeAccountUsesGoogleSignIn)
        try store.saveToken(OAuthToken(
            accessToken: "stale-at", refreshToken: "rt", expiresAt: .distantPast,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        ), for: email)
        appState.watchStatus = .watching

        // ...polls, and the poll's refresh is in flight...
        let poll = Task { await appState.pollInboxOnce() }
        await fulfillment(of: [transport.didStartRefresh], timeout: 2)

        // ...when the user switches the mailbox to an app password.
        let switched = await appState.testConnection(with: MailAccountCredentials(
            email: email, appPassword: "abcdefghijklmnop", host: "imap.gmail.com", port: 993
        ))
        XCTAssertTrue(switched)
        XCTAssertFalse(appState.activeAccountUsesGoogleSignIn)
        let statusAfterSwitch = appState.watchStatus

        // The old grant's refresh then fails.
        transport.completeRefresh(HTTPResponse(statusCode: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))
        await poll.value

        XCTAssertTrue(appState.isAccountConnected, "the app-password connection stays")
        XCTAssertFalse(appState.activeAccountUsesGoogleSignIn)
        XCTAssertEqual(appState.watchStatus, statusAfterSwitch, "the switched mailbox is not paused")
        XCTAssertNil(appState.watchError, "no Google re-authorization request")
        XCTAssertFalse(appState.activityEvents.contains { $0.kind == .authFailed })
    }

    func testSignInResultFromACancelledAddAccountSessionIsDropped() {
        var session = AddAccountFormSession()
        session.begin()
        let sessionA = session.id
        XCTAssertTrue(session.accepts(sessionA))

        // Cancel adding, then open "Add another account" again before the
        // browser returns.
        session.end()
        session.begin()
        let sessionB = session.id

        XCTAssertTrue(session.isActive)
        XCTAssertFalse(session.accepts(sessionA), "session A's result is not adopted by session B")
        XCTAssertTrue(session.accepts(sessionB))
    }

    func testClosingTheAddFormDropsItsResultButOutsideFlowsKeepTheirs() {
        var session = AddAccountFormSession()
        let primaryConnect = session.id
        session.end() // not adding: switching accounts etc. must not drop a primary flow
        XCTAssertTrue(session.accepts(primaryConnect))

        session.begin()
        let adding = session.id
        XCTAssertFalse(session.accepts(primaryConnect), "opening the add form supersedes a primary flow")
        session.end()
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.accepts(adding))
    }
}
