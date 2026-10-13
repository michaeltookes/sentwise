import SentwiseMail
import XCTest
@testable import Sentwise

/// Removing a Google mailbox (item 104): the local token delete is part of
/// the rollbackable removal, so a Keychain failure never orphans the
/// refresh token.
@MainActor
final class GoogleSignInRemovalTests: XCTestCase {

    private let state = "FIXED-STATE"

    private func connectedAppState(secrets: SecretStore) async throws -> (AppState, GmailAuthStore, FakeTransport) {
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        let store = GmailAuthStore(secrets: secrets)
        let exchange = """
        {"access_token":"fresh-at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer",\
        "scope":"https://mail.google.com/ openid","id_token":"\(GmailAuthCoordinatorTests.idToken(email: "me@gmail.com"))"}
        """
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data(exchange.utf8)))
        appState.googleMailAuth.install(GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: "1234-abc.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": self.state]) },
            browser: SpyBrowser(),
            makeState: { self.state }
        ))
        let connected = await appState.connectWithGoogle()
        XCTAssertTrue(connected)
        return (appState, store, transport)
    }

    func testTokenDeleteFailureAbortsTheRemovalAndKeepsEverythingConsistent() async throws {
        let secrets = TokenRemovalFailingSecretStore()
        let (appState, store, transport) = try await connectedAppState(secrets: secrets)
        let account = try XCTUnwrap(appState.savedAccounts.first)
        let requestsBefore = transport.requests.count

        secrets.failTokenRemoval = true
        appState.removeSavedAccount(account)

        XCTAssertNotNil(appState.connectionError, "the failed removal is reported")
        XCTAssertEqual(appState.savedAccounts.map(\.email), ["me@gmail.com"], "the account record stays")
        XCTAssertEqual(try secrets.value(for: .mailAppPassword(email: "me@gmail.com")), GoogleMailCredential.marker)
        XCTAssertTrue(store.hasToken(for: "me@gmail.com"), "the token stays with its account for a later retry")
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(transport.requests.count, requestsBefore, "nothing is revoked for a removal that didn't happen")

        // A retry once the Keychain recovers removes everything and revokes.
        secrets.failTokenRemoval = false
        appState.removeSavedAccount(account)

        XCTAssertTrue(appState.savedAccounts.isEmpty)
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"))
        XCTAssertNil(try secrets.value(for: .mailAppPassword(email: "me@gmail.com")))
        let deadline = Date().addingTimeInterval(2)
        while transport.lastURL != GoogleOAuth.revocationEndpoint, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.lastURL, GoogleOAuth.revocationEndpoint)
        XCTAssertEqual(transport.lastFields["token"], "rt")
    }
}

/// An in-memory secret store whose Google-token deletes can be made to fail.
final class TokenRemovalFailingSecretStore: SecretStore {
    private let base = InMemorySecretStore()
    var failTokenRemoval = false

    struct RemovalFailed: Error {}

    func set(_ value: String, for key: SecretKey) throws { try base.set(value, for: key) }
    func value(for key: SecretKey) throws -> String? { try base.value(for: key) }
    func remove(_ key: SecretKey) throws {
        if failTokenRemoval, key.rawValue.hasPrefix("gmail.oauthToken.") { throw RemovalFailed() }
        try base.remove(key)
    }
    func removeAll() throws { try base.removeAll() }
}

/// Disconnecting a Google mailbox, or switching it to an app password, takes
/// the token as a rollbackable first step too (item 104).
@MainActor
final class GoogleSignInDisconnectRollbackTests: XCTestCase {

    private func connected() async throws -> (AppState, GmailAuthStore, TokenRemovalFailingSecretStore, FakeTransport) {
        let secrets = TokenRemovalFailingSecretStore()
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        let store = GmailAuthStore(secrets: secrets)
        let exchange = """
        {"access_token":"fresh-at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer",\
        "scope":"https://mail.google.com/ openid","id_token":"\(GmailAuthCoordinatorTests.idToken(email: "me@gmail.com"))"}
        """
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data(exchange.utf8)))
        appState.googleMailAuth.install(GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: "1234-abc.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": "S"]) },
            browser: SpyBrowser(),
            makeState: { "S" }
        ))
        let didConnect = await appState.connectWithGoogle()
        XCTAssertTrue(didConnect)
        return (appState, store, secrets, transport)
    }

    func testDisconnectAbortsAndStaysConnectedWhenTheTokenDeleteFails() async throws {
        let (appState, store, secrets, transport) = try await connected()
        let requestsBefore = transport.requests.count

        secrets.failTokenRemoval = true
        appState.disconnectMail()

        XCTAssertNotNil(appState.connectionError)
        XCTAssertTrue(appState.isAccountConnected, "the disconnect didn't happen, so cleanup stays retryable")
        XCTAssertEqual(try secrets.value(for: .mailAppPassword(email: "me@gmail.com")), GoogleMailCredential.marker)
        XCTAssertTrue(store.hasToken(for: "me@gmail.com"))
        XCTAssertEqual(transport.requests.count, requestsBefore)

        secrets.failTokenRemoval = false
        appState.disconnectMail()
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"))
        XCTAssertNil(try secrets.value(for: .mailAppPassword(email: "me@gmail.com")))
    }

    func testSwitchToAnAppPasswordAbortsWhenTheTokenDeleteFails() async throws {
        let (appState, store, secrets, _) = try await connected()
        let appPassword = MailAccountCredentials(
            email: "me@gmail.com", appPassword: "abcdefghijklmnop", host: "imap.gmail.com", port: 993
        )

        secrets.failTokenRemoval = true
        let switched = await appState.testConnection(with: appPassword)

        XCTAssertFalse(switched)
        XCTAssertNotNil(appState.connectionError)
        XCTAssertTrue(appState.activeAccountUsesGoogleSignIn, "still a Google mailbox, marker intact")
        XCTAssertEqual(try secrets.value(for: .mailAppPassword(email: "me@gmail.com")), GoogleMailCredential.marker)
        XCTAssertTrue(store.hasToken(for: "me@gmail.com"))

        secrets.failTokenRemoval = false
        let retried = await appState.testConnection(with: appPassword)
        XCTAssertTrue(retried)
        XCTAssertFalse(appState.activeAccountUsesGoogleSignIn)
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"))
    }
}
