import SentwiseMail
import XCTest
@testable import Sentwise

/// A Google sign-in started from Settings belongs to that Settings session
/// (item 104): closing and reopening Settings while the chooser is open
/// discards the late result, success or failure, like the app-password path.
@MainActor
final class GoogleSignInSettingsSessionTests: XCTestCase {

    private let state = "FIXED-STATE"

    private func makeAppState(listener: GatedRedirectListener) -> (AppState, GmailAuthStore) {
        let secrets = InMemorySecretStore()
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

    func testSuccessAfterSettingsReopenedIsNotAdopted() async throws {
        let listener = GatedRedirectListener(redirectURI: "http://127.0.0.1:9999")
        let (appState, store) = makeAppState(listener: listener)

        let connect = Task { await appState.connectWithGoogle(messageSurface: .settings) }
        await fulfillment(of: [listener.didStartWaiting], timeout: 2)
        appState.resetTransientSettingsMessages() // Settings closed and reopened
        listener.release(["code": "code", "state": state])
        let connected = await connect.value

        XCTAssertFalse(connected)
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertTrue(appState.savedAccounts.isEmpty)
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"), "the discarded flow keeps no grant")
        XCTAssertNil(appState.connectionError(for: .settings))
    }

    func testFailureAfterSettingsReopenedLeavesTheNewSessionClean() async throws {
        let listener = GatedRedirectListener(redirectURI: "http://127.0.0.1:9999")
        let (appState, _) = makeAppState(listener: listener)

        let connect = Task { await appState.connectWithGoogle(messageSurface: .settings) }
        await fulfillment(of: [listener.didStartWaiting], timeout: 2)
        appState.resetTransientSettingsMessages()
        listener.release(["error": "access_denied", "state": state])
        let connected = await connect.value

        XCTAssertFalse(connected)
        XCTAssertNil(appState.connectionError(for: .settings), "a stale failure never repopulates the cleared bucket")
        XCTAssertNil(appState.settingsTransientMessages.connectionError)
    }

    func testSettingsFlowStillConnectsWithinTheSameSession() async throws {
        let listener = GatedRedirectListener(redirectURI: "http://127.0.0.1:9999")
        let (appState, store) = makeAppState(listener: listener)

        let connect = Task { await appState.connectWithGoogle(messageSurface: .settings) }
        await fulfillment(of: [listener.didStartWaiting], timeout: 2)
        listener.release(["code": "code", "state": state])
        let connected = await connect.value

        XCTAssertTrue(connected)
        XCTAssertTrue(store.hasToken(for: "me@gmail.com"))
    }
}
