import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class GoogleTokenRemovalReviewTests: XCTestCase {
    private let email = "me@gmail.com"
    private let state = "REMOVAL-STATE"
    private let clientID = "1234-abc.apps.googleusercontent.com"

    private enum Removal {
        case disconnect, savedAccount, appPassword
    }

    private var exchangeJSON: String {
        """
        {"access_token":"fresh-at","refresh_token":"fresh-rt","expires_in":3600,\
        "scope":"https://mail.google.com/ openid","id_token":"\(GmailAuthCoordinatorTests.idToken(email: email))"}
        """
    }

    private func connected() async throws -> (AppState, GmailAuthStore, TokenRemovalFailingSecretStore) {
        let secrets = TokenRemovalFailingSecretStore()
        let appState = AppState(
            persistence: AppStateMemoryPersistence(), secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        let store = GmailAuthStore(secrets: secrets)
        appState.googleMailAuth.install(coordinator(
            store: store,
            transport: FakeTransport(response: HTTPResponse(statusCode: 200, body: Data(exchangeJSON.utf8)))
        ))
        let didConnect = await appState.connectWithGoogle()
        XCTAssertTrue(didConnect)
        return (appState, store, secrets)
    }

    private func coordinator(
        store: GmailAuthStore, transport: HTTPTransport, browser: SpyBrowser = SpyBrowser()
    ) -> GmailAuthCoordinator {
        GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: clientID), store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": self.state]) },
            browser: browser, revocationWaitTimeout: 0.05, makeState: { self.state }
        )
    }

    private func remove(_ removal: Removal, from appState: AppState) async throws {
        switch removal {
        case .disconnect:
            appState.disconnectMail()
        case .savedAccount:
            appState.removeSavedAccount(try XCTUnwrap(appState.savedAccounts.first))
        case .appPassword:
            _ = await appState.testConnection(with: MailAccountCredentials(
                email: email, appPassword: "abcdefghijklmnop", host: "imap.gmail.com", port: 993
            ))
        }
    }

    func testImmediateAuthorizationAfterDisconnectWaitsForRevocation() async throws {
        try await assertImmediateAuthorizationWaits(after: .disconnect)
    }

    func testImmediateAuthorizationAfterAccountRemovalWaitsForRevocation() async throws {
        try await assertImmediateAuthorizationWaits(after: .savedAccount)
    }

    func testImmediateAuthorizationAfterPasswordSwitchWaitsForRevocation() async throws {
        try await assertImmediateAuthorizationWaits(after: .appPassword)
    }

    private func assertImmediateAuthorizationWaits(after removal: Removal) async throws {
        let (appState, store, _) = try await connected()
        let transport = GatedRefreshTransport(
            gatedURL: GoogleOAuth.revocationEndpoint,
            otherResponse: HTTPResponse(statusCode: 200, body: Data(exchangeJSON.utf8))
        )
        let browser = SpyBrowser()
        let coordinator = coordinator(store: store, transport: transport, browser: browser)
        appState.googleMailAuth.install(coordinator)

        try await remove(removal, from: appState)
        XCTAssertFalse(store.hasToken(for: email))
        // Do not yield to a background revocation task before starting consent.
        do {
            _ = try await coordinator.authorize(loginHint: email)
            XCTFail("new consent must wait for the removal's revocation")
        } catch {
            XCTAssertEqual(error as? GmailAuthError, .revocationPending)
        }
        XCTAssertNil(browser.openedURL)

        await fulfillment(of: [transport.didStartRefresh], timeout: 2)
        XCTAssertEqual(transport.lastGatedFields["token"], "fresh-rt")
        transport.completeRefresh(HTTPResponse(statusCode: 200, body: Data()))
        let replacement = try await coordinator.authorize(loginHint: email)
        XCTAssertEqual(replacement.email, email)
        XCTAssertNotNil(browser.openedURL)
        XCTAssertEqual(try store.loadToken(for: email), replacement.token)
    }

    func testUnconfiguredAccountRemovalKeepsCorruptEntryUntilDeletionSucceeds() async throws {
        try await assertUnconfiguredCleanup(.savedAccount)
    }

    func testUnconfiguredDisconnectKeepsCorruptEntryUntilDeletionSucceeds() async throws {
        try await assertUnconfiguredCleanup(.disconnect)
    }

    func testUnconfiguredPasswordSwitchKeepsCorruptEntryUntilDeletionSucceeds() async throws {
        try await assertUnconfiguredCleanup(.appPassword)
    }

    private func assertUnconfiguredCleanup(_ removal: Removal) async throws {
        let (appState, _, secrets) = try await connected()
        appState.googleMailAuth.install(nil)
        let key = SecretKey.gmailOAuthToken(email: email)
        try secrets.set("not-json", for: key)
        secrets.failTokenRemoval = true

        try await remove(removal, from: appState)

        XCTAssertNotNil(appState.connectionError)
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(appState.savedAccounts.map(\.email), [email])
        XCTAssertEqual(try secrets.value(for: key), "not-json")
        XCTAssertEqual(try secrets.value(for: .mailAppPassword(email: email)), GoogleMailCredential.marker)

        secrets.failTokenRemoval = false
        try await remove(removal, from: appState)

        XCTAssertNil(appState.connectionError)
        XCTAssertNil(try secrets.value(for: key))
        XCTAssertFalse(appState.activeAccountUsesGoogleSignIn)
        switch removal {
        case .savedAccount:
            XCTAssertTrue(appState.savedAccounts.isEmpty)
        case .disconnect:
            XCTAssertFalse(appState.isAccountConnected)
        case .appPassword:
            XCTAssertEqual(try secrets.value(for: .mailAppPassword(email: email)), "abcdefghijklmnop")
        }
    }

    func testUnconfiguredServiceDeletesUndecodableEntriesAndPreservesOtherAccounts() async throws {
        let secrets = InMemorySecretStore()
        let store = GmailAuthStore(secrets: secrets)
        let service = GoogleMailAuthService(coordinator: nil, tokenStore: store)
        let key = SecretKey.gmailOAuthToken(email: email)
        let otherKey = SecretKey.gmailOAuthToken(email: "other@gmail.com")
        try secrets.set("other-account-material", for: otherKey)

        for raw in ["not-json", #"{"accessToken":"incompatible-schema"}"#] {
            try secrets.set(raw, for: key)
            XCTAssertNil(try service.removeLocalToken(email))
            XCTAssertNil(try secrets.value(for: key))
            try secrets.set(raw, for: key)
            await service.disconnect(email)
            XCTAssertNil(try secrets.value(for: key))
            XCTAssertEqual(try secrets.value(for: otherKey), "other-account-material")
        }
        XCTAssertNil(try service.removeLocalToken(email), "deleting an absent entry remains safe")
        await service.disconnect(email)
    }

    func testUnconfiguredRemovalReturnsDecodedTokenForRollback() throws {
        let store = GmailAuthStore(secrets: InMemorySecretStore())
        let service = GoogleMailAuthService(coordinator: nil, tokenStore: store)
        let token = OAuthToken(
            accessToken: "old-at", refreshToken: "old-rt", expiresAt: .distantFuture,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        )
        try store.saveToken(token, for: email)

        let removed = try XCTUnwrap(service.removeLocalToken(email))

        XCTAssertEqual(removed, token)
        XCTAssertFalse(store.hasToken(for: email))
        try service.restoreLocalToken(removed, for: email)
        XCTAssertEqual(try store.loadToken(for: email), token)
    }
}
