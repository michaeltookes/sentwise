import SentwiseMail
import XCTest
@testable import Sentwise

/// Races between "Sign in with Google" and the rest of the app (item 104):
/// erase-all during a sign-in, and disconnects during a token refresh.
@MainActor
final class GoogleSignInRaceTests: XCTestCase {

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

    // MARK: - Erase all local data during sign-in

    func testEraseWhileBrowserIsOpenCancelsTheSignInAndKeepsNoToken() async throws {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        let store = GmailAuthStore(secrets: secrets)
        let listener = GatedRedirectListener(redirectURI: "http://127.0.0.1:9999")
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data(exchangeJSON.utf8)))
        appState.googleMailAuth.install(GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: clientID),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { listener },
            browser: SpyBrowser(),
            makeState: { self.state }
        ))

        let connect = Task { await appState.connectWithGoogle() }
        await fulfillment(of: [listener.didStartWaiting], timeout: 2)

        await appState.eraseAllLocalData()
        // The browser comes back after the erase with a valid code.
        listener.release(["code": "code", "state": state])
        let connected = await connect.value

        XCTAssertFalse(connected)
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"), "an erased app never recreates a Google token")
        XCTAssertNil(try secrets.value(for: .mailAppPassword(email: "me@gmail.com")))
        XCTAssertTrue(appState.savedAccounts.isEmpty)
        XCTAssertFalse(transport.requests.contains { $0.fields["grant_type"] == "authorization_code" },
                       "the canceled flow never exchanges its code")
    }

    func testEraseDuringVerificationDropsTheGrantEvenIfTheFlowFinished() async throws {
        let secrets = InMemorySecretStore()
        let provider = SuspendedAppMailProvider()
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        let store = GmailAuthStore(secrets: secrets)
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data(exchangeJSON.utf8)))
        appState.googleMailAuth.install(GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: clientID),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": self.state]) },
            browser: SpyBrowser(),
            makeState: { self.state }
        ))

        let connect = Task { await appState.connectWithGoogle() }
        await fulfillment(of: [provider.didStartVerification], timeout: 2)
        XCTAssertTrue(store.hasToken(for: "me@gmail.com"), "the flow stored its token before verification")

        await appState.eraseAllLocalData()
        provider.complete(with: .success(()))
        let connected = await connect.value

        XCTAssertFalse(connected)
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"))
        XCTAssertNil(try secrets.value(for: .mailAppPassword(email: "me@gmail.com")))
        XCTAssertTrue(appState.savedAccounts.isEmpty)
    }

    // MARK: - Disconnect during a token refresh

    private func makeRefreshHarness() throws -> (GmailAuthCoordinator, GmailAuthStore, GatedRefreshTransport) {
        let store = GmailAuthStore(secrets: InMemorySecretStore())
        try store.saveToken(OAuthToken(
            accessToken: "stale-at", refreshToken: "rt", expiresAt: .distantPast,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        ), for: "me@gmail.com")
        let transport = GatedRefreshTransport()
        let coordinator = GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: clientID),
            store: store,
            tokenService: OAuthTokenService(transport: transport)
        )
        return (coordinator, store, transport)
    }

    private let refreshedJSON = #"{"access_token":"late-at","expires_in":3600,"scope":"https://mail.google.com/"}"#

    func testRefreshThatLandsAfterDisconnectIsNotSavedOrReturned() async throws {
        let (coordinator, store, transport) = try makeRefreshHarness()

        let refresh = Task { try await coordinator.validAccessToken(for: "me@gmail.com") }
        let waiter = Task { try await coordinator.validAccessToken(for: "ME@gmail.com") }
        await fulfillment(of: [transport.didStartRefresh], timeout: 2)

        await coordinator.disconnect("me@gmail.com")
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"))
        transport.completeRefresh(HTTPResponse(statusCode: 200, body: Data(refreshedJSON.utf8)))

        for task in [refresh, waiter] {
            do {
                _ = try await task.value
                XCTFail("a refresh outliving its mailbox must not hand out a token")
            } catch {
                XCTAssertEqual(error as? GmailAuthError, .notConnected)
            }
        }
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"), "the late response never re-saves the token")
        XCTAssertEqual(transport.refreshCount, 1, "the waiter shared the one refresh")
    }

    func testRefreshThatLandsAfterInvalidateAllIsNotSaved() async throws {
        let (coordinator, store, transport) = try makeRefreshHarness()

        let refresh = Task { try await coordinator.validAccessToken(for: "me@gmail.com") }
        await fulfillment(of: [transport.didStartRefresh], timeout: 2)

        coordinator.invalidateAll()
        try store.deleteToken(for: "me@gmail.com") // what erase-all's Keychain wipe does
        transport.completeRefresh(HTTPResponse(statusCode: 200, body: Data(refreshedJSON.utf8)))

        do {
            _ = try await refresh.value
            XCTFail("expected the invalidated refresh to fail")
        } catch {
            XCTAssertEqual(error as? GmailAuthError, .notConnected)
        }
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"))
    }

    func testRefreshAfterReconnectUsesTheNewGeneration() async throws {
        let (coordinator, store, transport) = try makeRefreshHarness()
        await coordinator.disconnect("me@gmail.com")
        try store.saveToken(OAuthToken(
            accessToken: "new-at", refreshToken: "rt2", expiresAt: .distantPast,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        ), for: "me@gmail.com")

        let refresh = Task { try await coordinator.validAccessToken(for: "me@gmail.com") }
        await fulfillment(of: [transport.didStartRefresh], timeout: 2)
        transport.completeRefresh(HTTPResponse(statusCode: 200, body: Data(refreshedJSON.utf8)))

        let accessToken = try await refresh.value
        XCTAssertEqual(accessToken, "late-at")
        XCTAssertEqual(try store.loadToken(for: "me@gmail.com")?.accessToken, "late-at")
    }

    // MARK: - Helpers

    func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("condition not met within \(timeout)s", file: file, line: line)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Gated fakes

/// A redirect listener that waits until the test hands it the redirect.
final class GatedRedirectListener: RedirectListener, @unchecked Sendable {
    let didStartWaiting = XCTestExpectation(description: "waiting for the browser redirect")
    private let redirectURI: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?

    init(redirectURI: String) {
        self.redirectURI = redirectURI
    }

    func start() async throws -> String { redirectURI }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            didStartWaiting.fulfill()
        }
    }

    func release(_ params: [String: String]) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: params)
    }

    func stop() {}
}

/// A transport whose refresh requests wait until the test answers them;
/// every other request (e.g. revoke) answers 200 immediately.
final class GatedRefreshTransport: HTTPTransport, @unchecked Sendable {
    let didStartRefresh = XCTestExpectation(description: "token refresh started")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private(set) var refreshCount = 0

    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        guard fields["grant_type"] == "refresh_token" else {
            return HTTPResponse(statusCode: 200, body: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            refreshCount += 1
            self.continuation = continuation
            lock.unlock()
            didStartRefresh.fulfill()
        }
    }

    func completeRefresh(_ response: HTTPResponse) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
    }
}
