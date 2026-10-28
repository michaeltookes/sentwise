import SentwiseMail
import XCTest
@testable import Sentwise

/// App-password and Google connection attempts share one operation guard
/// (item 104): whichever starts last wins, the other's result is never
/// committed, and the busy flag always clears.
@MainActor
final class GoogleSignInAttemptTests: XCTestCase {

    private let state = "FIXED-STATE"
    private let yahoo = MailAccountCredentials(
        email: "me@yahoo.com", appPassword: "abcdefghijklmnop", host: "imap.mail.yahoo.com", port: 993
    )

    private func makeAppState(
        provider: MailProvider,
        listener: RedirectListener
    ) -> (AppState, GmailAuthStore) {
        let secrets = InMemorySecretStore()
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        let store = GmailAuthStore(secrets: secrets)
        let exchange = """
        {"access_token":"fresh-at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer",\
        "scope":"https://mail.google.com/ openid","id_token":"\(GmailAuthCoordinatorTests.idToken(email: "me@gmail.com"))"}
        """
        appState.googleMailAuth.install(GmailAuthCoordinator(
            client: OAuthProviderConfiguration.google(clientID: "1234-abc.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: FakeTransport(
                response: HTTPResponse(statusCode: 200, body: Data(exchange.utf8))
            )),
            makeListener: { listener },
            browser: SpyBrowser(),
            makeState: { self.state }
        ))
        return (appState, store)
    }

    func testAppPasswordAttemptStartedMidGoogleFlowCancelsTheGoogleResult() async throws {
        let listener = GatedRedirectListener(redirectURI: "http://127.0.0.1:9999")
        let (appState, store) = makeAppState(provider: FakeAppMailProvider(result: .success(())), listener: listener)

        let google = Task { await appState.connectWithGoogle() }
        await fulfillment(of: [listener.didStartWaiting], timeout: 2)

        let passwordConnected = await appState.testConnection(with: yahoo)
        listener.release(["code": "code", "state": state])
        let googleConnected = await google.value

        XCTAssertTrue(passwordConnected)
        XCTAssertFalse(googleConnected)
        XCTAssertEqual(appState.mailEmail, "me@yahoo.com")
        XCTAssertFalse(appState.activeAccountUsesGoogleSignIn)
        XCTAssertEqual(appState.savedAccounts.map(\.email), ["me@yahoo.com"])
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"), "the superseded Google flow keeps no grant")
        XCTAssertFalse(appState.isConnecting)
    }

    func testGoogleAttemptStartedMidAppPasswordTestCancelsThePasswordResult() async throws {
        let provider = PasswordGatedMailProvider()
        let listener = FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": state])
        let (appState, store) = makeAppState(provider: provider, listener: listener)

        let password = Task { await appState.testConnection(with: yahoo) }
        await fulfillment(of: [provider.didStartPasswordVerification], timeout: 2)
        XCTAssertTrue(appState.isConnecting)

        let googleConnected = await appState.connectWithGoogle()
        provider.completePasswordVerification()
        let passwordConnected = await password.value

        XCTAssertTrue(googleConnected)
        XCTAssertFalse(passwordConnected, "the superseded app-password result is never committed")
        XCTAssertEqual(appState.mailEmail, "me@gmail.com")
        XCTAssertTrue(appState.activeAccountUsesGoogleSignIn)
        XCTAssertEqual(appState.savedAccounts.map(\.email), ["me@gmail.com"])
        XCTAssertTrue(store.hasToken(for: "me@gmail.com"))
        XCTAssertFalse(appState.isConnecting, "the superseded attempt can't strand or steal the busy flag")
    }
}

/// Suspends app-password verifications until the test releases them; XOAUTH2
/// (Google) verifications succeed immediately.
final class PasswordGatedMailProvider: MailProvider, @unchecked Sendable {
    let didStartPasswordVerification = XCTestExpectation(description: "app-password verification started")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        guard (credentials.oauthAccessToken ?? "").isEmpty else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            didStartPasswordVerification.fulfill()
        }
    }

    func completePasswordVerification() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, limit: Int
    ) async throws -> [MailMessage] { [] }

    func fetchBodyText(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, uid: UInt32, expectedUIDValidity: UInt32?
    ) async throws -> Data { Data() }

    func appendMessage(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, rfc822: Data, flags: [MailFlag]
    ) async throws {}
}
