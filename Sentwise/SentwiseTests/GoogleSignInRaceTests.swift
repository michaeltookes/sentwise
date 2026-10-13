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

    // MARK: - Removing a saved mailbox during sign-in

    private func connectedGoogleAppState(
        listener: RedirectListener
    ) async throws -> (AppState, GmailAuthStore, InMemorySecretStore, GmailAuthCoordinator) {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        let store = GmailAuthStore(secrets: secrets)
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data(exchangeJSON.utf8)))
        let first = GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: clientID),
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
            client: GoogleOAuthClientConfiguration(clientID: clientID),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { listener },
            browser: SpyBrowser(),
            makeState: { self.state }
        )
        appState.googleMailAuth.install(reconnecting)
        return (appState, store, secrets, reconnecting)
    }

    func testRemovingTheMailboxWhileTheBrowserIsOpenKeepsItRemoved() async throws {
        let listener = GatedRedirectListener(redirectURI: "http://127.0.0.1:9999")
        let (appState, store, secrets, _) = try await connectedGoogleAppState(listener: listener)
        let account = try XCTUnwrap(appState.savedAccounts.first)

        // No login hint, so only the removal mark (not the hint cancel) can stop it.
        let reconnect = Task { await appState.connectWithGoogle() }
        await fulfillment(of: [listener.didStartWaiting], timeout: 2)
        XCTAssertFalse(appState.isConnecting, "removal is allowed while the browser is open")

        appState.removeSavedAccount(account)
        listener.release(["code": "code", "state": state])
        let connected = await reconnect.value

        XCTAssertFalse(connected)
        XCTAssertTrue(appState.savedAccounts.isEmpty, "a late callback never restores the removed mailbox")
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil(try secrets.value(for: .mailAppPassword(email: "me@gmail.com")))
        try await waitUntil { !store.hasToken(for: "me@gmail.com") }
    }

    func testRemovingTheMailboxCancelsASignInStartedForIt() async throws {
        let listener = GatedRedirectListener(redirectURI: "http://127.0.0.1:9999")
        let (appState, store, _, _) = try await connectedGoogleAppState(listener: listener)
        let account = try XCTUnwrap(appState.savedAccounts.first)

        let reconnect = Task { await appState.connectWithGoogle(loginHint: "Me@gmail.com") }
        await fulfillment(of: [listener.didStartWaiting], timeout: 2)
        appState.removeSavedAccount(account)
        listener.release(["code": "code", "state": state])
        let connected = await reconnect.value

        XCTAssertFalse(connected)
        XCTAssertNil(appState.connectionError, "a canceled sign-in is quiet")
        XCTAssertTrue(appState.savedAccounts.isEmpty)
        try await waitUntil { !store.hasToken(for: "me@gmail.com") }
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

    func testReauthorizingDuringARefreshRetiresTheOldRefresh() async throws {
        let store = GmailAuthStore(secrets: InMemorySecretStore())
        try store.saveToken(OAuthToken(
            accessToken: "stale-at", refreshToken: "old-rt", expiresAt: .distantPast,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        ), for: "me@gmail.com")
        let exchange = exchangeJSON.replacingOccurrences(of: "fresh-at", with: "new-at")
        let transport = GatedRefreshTransport(otherResponse: HTTPResponse(statusCode: 200, body: Data(exchange.utf8)))
        let coordinator = GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: clientID),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": self.state]) },
            browser: SpyBrowser(),
            makeState: { self.state }
        )

        let oldRefresh = Task { try await coordinator.validAccessToken(for: "me@gmail.com") }
        await fulfillment(of: [transport.didStartRefresh], timeout: 2)

        _ = try await coordinator.authorize(loginHint: "me@gmail.com")
        let verified = try await coordinator.validAccessToken(for: "me@gmail.com")
        XCTAssertEqual(verified, "new-at", "verification uses the new grant instead of joining the old refresh")

        // The old refresh finally answers; it must neither overwrite nor reject the new grant.
        transport.completeRefresh(HTTPResponse(statusCode: 200, body: Data(refreshedJSON.utf8)))
        do {
            _ = try await oldRefresh.value
            XCTFail("the retired refresh must not hand out a token")
        } catch {
            XCTAssertEqual(error as? GmailAuthError, .notConnected)
        }
        XCTAssertEqual(try store.loadToken(for: "me@gmail.com")?.accessToken, "new-at")
        XCTAssertEqual(transport.refreshCount, 1)
    }

    // MARK: - Reconnect while a revoke is pending

    func testSlowRevokeNeverDeletesTheReplacementToken() async throws {
        let store = GmailAuthStore(secrets: InMemorySecretStore())
        try store.saveToken(OAuthToken(
            accessToken: "old-at", refreshToken: "old-rt", expiresAt: .distantFuture,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        ), for: "me@gmail.com")
        let transport = GatedRefreshTransport(gatedURL: GoogleOAuth.revocationEndpoint)
        let service = GoogleMailAuthService(
            coordinator: GmailAuthCoordinator(
                client: GoogleOAuthClientConfiguration(clientID: clientID),
                store: store,
                tokenService: OAuthTokenService(transport: transport)
            ),
            tokenStore: store
        )

        let disconnect = Task { await service.disconnect("me@gmail.com") }
        await fulfillment(of: [transport.didStartRefresh], timeout: 2)
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"), "local removal happens before the revoke")

        // The user signs in again while the old revoke is still out.
        try store.saveToken(OAuthToken(
            accessToken: "new-at", refreshToken: "new-rt", expiresAt: .distantFuture,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        ), for: "me@gmail.com")
        transport.completeRefresh(HTTPResponse(statusCode: 200, body: Data()))
        await disconnect.value

        XCTAssertEqual(try store.loadToken(for: "me@gmail.com")?.accessToken, "new-at")
        XCTAssertEqual(transport.lastGatedFields["token"], "old-rt", "only the old grant was revoked")
    }

    // MARK: - Builds without a bundled client

    func testDisconnectWithoutAClientStillDeletesTheLocalToken() async throws {
        let store = GmailAuthStore(secrets: InMemorySecretStore())
        try store.saveToken(OAuthToken(
            accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        ), for: "me@gmail.com")
        let service = GoogleMailAuthService(coordinator: nil, tokenStore: store)
        XCTAssertFalse(service.isAvailable)

        await service.disconnect("me@gmail.com")

        XCTAssertFalse(store.hasToken(for: "me@gmail.com"))
    }

    func testRemovingAGoogleAccountInAnUnconfiguredBuildDeletesItsTokens() async throws {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
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
        await appState.connectWithGoogle()
        let account = try XCTUnwrap(appState.savedAccounts.first)
        XCTAssertTrue(store.hasToken(for: "me@gmail.com"))

        // A later build ships without the client (or it was pulled).
        appState.googleMailAuth.install(nil)
        let requestsBefore = transport.requests.count
        appState.removeSavedAccount(account)

        try await waitUntil { !store.hasToken(for: "me@gmail.com") }
        XCTAssertEqual(transport.requests.count, requestsBefore, "no client, so no remote revoke")
    }

    func testSwitchingToAnAppPasswordInAnUnconfiguredBuildDeletesTheTokens() async throws {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        let store = GmailAuthStore(secrets: secrets)
        appState.googleMailAuth.install(GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: clientID),
            store: store,
            tokenService: OAuthTokenService(transport: FakeTransport(
                response: HTTPResponse(statusCode: 200, body: Data(exchangeJSON.utf8))
            )),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": self.state]) },
            browser: SpyBrowser(),
            makeState: { self.state }
        ))
        await appState.connectWithGoogle()
        appState.googleMailAuth.install(nil)

        let connected = await appState.testConnection(with: MailAccountCredentials(
            email: "me@gmail.com", appPassword: "abcdefghijklmnop", host: "imap.gmail.com", port: 993
        ))

        XCTAssertTrue(connected)
        try await waitUntil { !store.hasToken(for: "me@gmail.com") }
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

/// A transport whose refresh requests (or, with `gatedURL`, requests to that
/// URL) wait until the test answers them; every other request answers
/// `otherResponse` immediately.
final class GatedRefreshTransport: HTTPTransport, @unchecked Sendable {
    let didStartRefresh = XCTestExpectation(description: "gated request started")
    private let gatedURL: URL?
    private let otherResponse: HTTPResponse
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private(set) var refreshCount = 0
    private(set) var lastGatedFields: [String: String] = [:]

    init(gatedURL: URL? = nil, otherResponse: HTTPResponse = HTTPResponse(statusCode: 200, body: Data())) {
        self.gatedURL = gatedURL
        self.otherResponse = otherResponse
    }

    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        let isGated = gatedURL.map { $0 == url } ?? (fields["grant_type"] == "refresh_token")
        guard isGated else { return otherResponse }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            refreshCount += 1
            lastGatedFields = fields
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
