import SentwiseMail
import XCTest
@testable import Sentwise

/// A disconnect supersedes reauthorization even before mail verification starts.
@MainActor
final class GoogleSignInDisconnectRaceTests: XCTestCase {
    private let state = "FIXED-STATE"
    private let clientID = "1234-abc.apps.googleusercontent.com"

    private var exchangeJSON: String {
        """
        {"access_token":"fresh-at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer",\
        "scope":"https://mail.google.com/ openid","id_token":"\(GmailAuthCoordinatorTests.idToken(email: "me@gmail.com"))"}
        """
    }

    private func makeAppState(secrets: InMemorySecretStore) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    private func connectedGoogleAppState(
        listener: RedirectListener,
        reauthorizationTransport: HTTPTransport? = nil
    ) async throws -> (AppState, GmailAuthStore, InMemorySecretStore) {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        let store = GmailAuthStore(secrets: secrets)
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data(exchangeJSON.utf8)))
        let first = GmailAuthCoordinator(
            client: OAuthProviderConfiguration.google(clientID: clientID),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": self.state]) },
            browser: SpyBrowser(),
            makeState: { self.state }
        )
        appState.googleMailAuth.install(first)
        let connected = await appState.connectWithGoogle()
        XCTAssertTrue(connected)
        let reconnecting = GmailAuthCoordinator(
            client: OAuthProviderConfiguration.google(clientID: clientID),
            store: store,
            tokenService: OAuthTokenService(transport: reauthorizationTransport ?? transport),
            makeListener: { listener },
            browser: SpyBrowser(),
            makeState: { self.state }
        )
        appState.googleMailAuth.install(reconnecting)
        return (appState, store, secrets)
    }

    func testDisconnectWhileReauthorizationBrowserIsOpenKeepsMailboxDisconnected() async throws {
        let listener = GatedRedirectListener(redirectURI: "http://127.0.0.1:9999")
        let (appState, store, secrets) = try await connectedGoogleAppState(listener: listener)
        let reconnect = Task {
            await appState.connectWithGoogle(loginHint: "me@gmail.com", requireHintMatch: true)
        }
        await fulfillment(of: [listener.didStartWaiting], timeout: 2)
        XCTAssertFalse(appState.isConnecting)
        let attempt = appState.googleMailAuth.connectionAttempt

        appState.disconnectMail()
        XCTAssertFalse(appState.isCurrentMailConnectionAttempt(attempt))
        listener.release(["code": "code", "state": state])
        let connected = await reconnect.value

        XCTAssertFalse(connected)
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"))
        XCTAssertNil(try secrets.value(for: .mailAppPassword(email: "me@gmail.com")))
        XCTAssertEqual(appState.savedAccounts.map(\.email), ["me@gmail.com"])
        XCTAssertNil(appState.connectionError, "a canceled reauthorization stays quiet")
    }

    func testDisconnectDuringCodeExchangeDropsTheLateAuthorization() async throws {
        let listener = FakeRedirectListener(
            redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": state]
        )
        let transport = GatedRefreshTransport(gatedURL: GoogleOAuth.tokenEndpoint)
        let (appState, store, secrets) = try await connectedGoogleAppState(
            listener: listener, reauthorizationTransport: transport
        )
        let reconnect = Task {
            await appState.connectWithGoogle(loginHint: "me@gmail.com", requireHintMatch: true)
        }
        await fulfillment(of: [transport.didStartRefresh], timeout: 2)
        XCTAssertFalse(appState.isConnecting)

        appState.disconnectMail(purgeLocalData: true)
        transport.completeRefresh(HTTPResponse(statusCode: 200, body: Data(exchangeJSON.utf8)))
        let connected = await reconnect.value

        XCTAssertFalse(connected)
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"))
        XCTAssertNil(try secrets.value(for: .mailAppPassword(email: "me@gmail.com")))
        XCTAssertNil(appState.connectionError)
    }
}
