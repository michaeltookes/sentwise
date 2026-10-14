import XCTest
@testable import Sentwise

/// The "Sign in with Google" engine (item 104): the bundled-client PKCE flow,
/// its phase state machine, per-account token storage, refresh, and revoke.
@MainActor
final class GmailAuthCoordinatorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let state = "FIXED-STATE"
    private let client = GoogleOAuthClientConfiguration(clientID: "cid.apps.googleusercontent.com", clientSecret: "secret")
    private var grantedScopes: String { "\(GoogleOAuth.mailScope) openid https://www.googleapis.com/auth/userinfo.email" }

    private struct Harness {
        let coordinator: GmailAuthCoordinator
        let store: GmailAuthStore
        let secrets: InMemorySecretStore
        let browser: SpyBrowser
        let listener: FakeRedirectListener
        let transport: FakeTransport
    }

    private func makeHarness(
        redirect: [String: String]? = nil,
        tokenJSON: String? = nil,
        tokenStatus: Int = 200,
        waitError: Error? = nil
    ) -> Harness {
        let secrets = InMemorySecretStore()
        let store = GmailAuthStore(secrets: secrets)
        let transport = FakeTransport(
            response: HTTPResponse(statusCode: tokenStatus, body: Data((tokenJSON ?? exchangeJSON()).utf8))
        )
        let listener = FakeRedirectListener(
            redirectURI: "http://127.0.0.1:9999",
            params: redirect ?? ["code": "auth-code", "state": state],
            waitError: waitError
        )
        let browser = SpyBrowser()
        let coordinator = GmailAuthCoordinator(
            client: client,
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { listener },
            browser: browser,
            redirectTimeout: 300,
            now: { self.now },
            makeState: { self.state }
        )
        return Harness(coordinator: coordinator, store: store, secrets: secrets,
                       browser: browser, listener: listener, transport: transport)
    }

    private func exchangeJSON(email: String = "me@gmail.com", scope: String? = nil, refreshToken: Bool = true) -> String {
        let refresh = refreshToken ? #""refresh_token":"rt","# : ""
        return """
        {"access_token":"at",\(refresh)"expires_in":3600,"token_type":"Bearer",\
        "scope":"\(scope ?? grantedScopes)","id_token":"\(Self.idToken(email: email))"}
        """
    }

    static func idToken(email: String, verified: Any = true) -> String {
        let payload: [String: Any] = ["iss": "https://accounts.google.com", "email": email, "email_verified": verified]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return "eyJhbGciOiJSUzI1NiJ9.\(data.base64URLEncodedString()).sig"
    }

    private func storedToken(expiresAt: Date, refreshToken: String? = "rt") -> OAuthToken {
        OAuthToken(accessToken: "stored-at", refreshToken: refreshToken,
                   expiresAt: expiresAt, scope: grantedScopes, tokenType: "Bearer")
    }

    // MARK: - Authorize

    func testAuthorizeStoresTokenUnderIDTokenEmailAndOpensBundledClientURL() async throws {
        let harness = makeHarness()
        var phases: [GmailAuthPhase] = []
        harness.coordinator.onPhaseChange = { phases.append($0) }

        let result = try await harness.coordinator.authorize(loginHint: "me@gmail.com")

        XCTAssertEqual(result.email, "me@gmail.com")
        XCTAssertEqual(result.token.accessToken, "at")
        XCTAssertNil(result.token.idToken, "the ID token is read once and never stored")
        XCTAssertTrue(harness.store.hasToken(for: "ME@gmail.com"), "token keyed by normalized email")
        XCTAssertTrue(harness.listener.stopped, "listener is always stopped")
        XCTAssertEqual(phases, [.awaitingBrowser, .exchangingCode, .idle])
        XCTAssertEqual(harness.coordinator.phase, .idle)

        let opened = try XCTUnwrap(harness.browser.openedURL)
        let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let byName = items.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        XCTAssertEqual(byName["client_id"], "cid.apps.googleusercontent.com")
        XCTAssertEqual(byName["redirect_uri"], "http://127.0.0.1:9999")
        XCTAssertEqual(byName["state"], state)
        XCTAssertEqual(byName["scope"], "https://mail.google.com/ openid email")
        XCTAssertEqual(byName["login_hint"], "me@gmail.com")
        XCTAssertEqual(byName["code_challenge_method"], "S256")
        XCTAssertEqual(harness.transport.lastFields["client_secret"], "secret")
    }

    func testAuthorizeOmitsBlankLoginHint() async throws {
        let harness = makeHarness()
        _ = try await harness.coordinator.authorize(loginHint: "  ")
        let opened = try XCTUnwrap(harness.browser.openedURL)
        XCTAssertFalse(opened.absoluteString.contains("login_hint"))
    }

    func testAuthorizeRejectsStateMismatchAndLandsInFailed() async {
        let harness = makeHarness(redirect: ["code": "c", "state": "WRONG"])
        await assertThrows(try await harness.coordinator.authorize(), OAuthError.stateMismatch)
        guard case .failed = harness.coordinator.phase else {
            return XCTFail("expected failed phase, got \(harness.coordinator.phase)")
        }
        XCTAssertFalse(harness.store.hasToken(for: "me@gmail.com"))
    }

    func testAuthorizeSurfacesConsentDenied() async {
        let harness = makeHarness(redirect: ["error": "access_denied", "state": state])
        await assertThrows(try await harness.coordinator.authorize(), OAuthError.authorizationDenied("access_denied"))
        XCTAssertEqual(harness.coordinator.phase, .failed("Google sign-in was canceled."))
    }

    func testAuthorizeTimesOutWaitingForRedirect() async {
        let harness = makeHarness(waitError: OAuthError.redirectTimedOut)
        await assertThrows(try await harness.coordinator.authorize(), OAuthError.redirectTimedOut)
        XCTAssertEqual(harness.listener.requestedTimeout, 300)
        XCTAssertTrue(harness.listener.stopped)
    }

    func testCancellationReturnsToIdleNotFailed() async {
        let harness = makeHarness(waitError: CancellationError())
        do {
            _ = try await harness.coordinator.authorize()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(harness.coordinator.phase, .idle)
    }

    func testAuthorizeRejectsTokenMissingMailScope() async {
        let harness = makeHarness(tokenJSON: exchangeJSON(scope: "openid email"))
        await assertThrows(
            try await harness.coordinator.authorize(),
            OAuthError.missingRequiredScopes([GoogleOAuth.mailScope])
        )
        XCTAssertFalse(harness.store.hasToken(for: "me@gmail.com"))
    }

    func testAuthorizeRequiresRefreshToken() async {
        let harness = makeHarness(tokenJSON: exchangeJSON(refreshToken: false))
        await assertThrows(try await harness.coordinator.authorize(), OAuthError.missingRefreshToken)
    }

    func testAuthorizeRequiresAnEmailInTheIDToken() async {
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"scope":"https://mail.google.com/"}"#
        let harness = makeHarness(tokenJSON: json)
        await assertThrows(try await harness.coordinator.authorize(), GmailAuthError.missingAccountEmail)
    }

    func testAuthorizeEnforcesHintMatchWhenRequired() async {
        let harness = makeHarness(tokenJSON: exchangeJSON(email: "other@gmail.com"))
        await assertThrows(
            try await harness.coordinator.authorize(loginHint: "me@gmail.com", requireHintMatch: true),
            GmailAuthError.accountMismatch(expected: "me@gmail.com", actual: "other@gmail.com")
        )
        XCTAssertFalse(harness.store.hasToken(for: "other@gmail.com"))
    }

    func testIDTokenEmailIgnoresUnverifiedAndMalformedTokens() {
        XCTAssertEqual(GoogleIDToken.email(fromIDToken: Self.idToken(email: "a@b.com")), "a@b.com")
        XCTAssertEqual(GoogleIDToken.email(fromIDToken: Self.idToken(email: "a@b.com", verified: "true")), "a@b.com")
        XCTAssertNil(GoogleIDToken.email(fromIDToken: Self.idToken(email: "a@b.com", verified: false)))
        XCTAssertNil(GoogleIDToken.email(fromIDToken: Self.idToken(email: "no-at-sign")))
        XCTAssertNil(GoogleIDToken.email(fromIDToken: "not-a-jwt"))
        XCTAssertNil(GoogleIDToken.email(fromIDToken: "a.!!!.c"))
    }

    // MARK: - Access tokens

    func testValidAccessTokenReturnsStoredWhenNotExpired() async throws {
        let harness = makeHarness()
        try harness.store.saveToken(storedToken(expiresAt: now.addingTimeInterval(3600)), for: "me@gmail.com")

        let accessToken = try await harness.coordinator.validAccessToken(for: "me@gmail.com")

        XCTAssertEqual(accessToken, "stored-at")
        XCTAssertTrue(harness.transport.requests.isEmpty, "no network when the token is fresh")
    }

    func testValidAccessTokenRefreshesWhenExpiredAndPersists() async throws {
        let harness = makeHarness(tokenJSON: """
        {"access_token":"refreshed-at","expires_in":3600,"scope":"\(grantedScopes)","token_type":"Bearer"}
        """)
        try harness.store.saveToken(storedToken(expiresAt: now.addingTimeInterval(-10)), for: "me@gmail.com")

        let accessToken = try await harness.coordinator.validAccessToken(for: "me@gmail.com")

        XCTAssertEqual(accessToken, "refreshed-at")
        XCTAssertEqual(harness.transport.lastFields["grant_type"], "refresh_token")
        let stored = try XCTUnwrap(harness.store.loadToken(for: "me@gmail.com"))
        XCTAssertEqual(stored.accessToken, "refreshed-at")
        XCTAssertEqual(stored.refreshToken, "rt", "refresh token carried forward")
    }

    func testRefreshWithoutScopePreservesStoredGrantAndPersistsNewToken() async throws {
        let harness = makeHarness(tokenJSON: #"{"access_token":"refreshed-at","expires_in":3600}"#)
        try harness.store.saveToken(storedToken(expiresAt: .distantPast), for: "me@gmail.com")

        let accessToken = try await harness.coordinator.validAccessToken(for: "me@gmail.com")

        XCTAssertEqual(accessToken, "refreshed-at")
        let stored = try XCTUnwrap(harness.store.loadToken(for: "me@gmail.com"))
        XCTAssertEqual(stored.scope, grantedScopes)
        XCTAssertEqual(stored.refreshToken, "rt")
        XCTAssertEqual(stored.accessToken, "refreshed-at")
    }

    func testRefreshWithExplicitlyReducedScopeStillFailsWithoutReplacingStoredGrant() async throws {
        for scope in ["openid", ""] {
            let harness = makeHarness(tokenJSON: """
            {"access_token":"refreshed-at","expires_in":3600,"scope":"\(scope)"}
            """)
            let original = storedToken(expiresAt: .distantPast)
            try harness.store.saveToken(original, for: "me@gmail.com")

            await assertThrows(
                try await harness.coordinator.validAccessToken(for: "me@gmail.com"),
                OAuthError.missingRequiredScopes([GoogleOAuth.mailScope])
            )

            XCTAssertEqual(try harness.store.loadToken(for: "me@gmail.com"), original)
        }
    }

    func testInvalidGrantOnRefreshRequiresReauthorization() async throws {
        let harness = makeHarness(
            tokenJSON: #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#,
            tokenStatus: 400
        )
        try harness.store.saveToken(storedToken(expiresAt: now.addingTimeInterval(-10)), for: "me@gmail.com")

        await assertThrows(
            try await harness.coordinator.validAccessToken(for: "me@gmail.com"),
            GmailAuthError.reauthorizationRequired
        )
    }

    func testValidAccessTokenWithoutStoredTokenIsNotConnected() async {
        let harness = makeHarness()
        await assertThrows(
            try await harness.coordinator.validAccessToken(for: "me@gmail.com"),
            GmailAuthError.notConnected
        )
    }

    func testTokensAreIsolatedPerAccount() async throws {
        let harness = makeHarness()
        try harness.store.saveToken(storedToken(expiresAt: now.addingTimeInterval(3600)), for: "a@gmail.com")
        XCTAssertTrue(harness.coordinator.isConnected("a@gmail.com"))
        XCTAssertFalse(harness.coordinator.isConnected("b@gmail.com"))
    }

    // MARK: - Disconnect

    func testRemoveLocalTokenDeletesUndecodableEntriesWithoutTouchingOtherAccounts() throws {
        let harness = makeHarness()
        let otherToken = storedToken(expiresAt: .distantFuture)
        try harness.store.saveToken(otherToken, for: "other@gmail.com")
        let key = SecretKey.gmailOAuthToken(email: "me@gmail.com")
        for json in ["not-json", #"{"refreshToken":"rt","expiresAt":"incompatible"}"#] {
            try harness.secrets.set(json, for: key)

            XCTAssertNil(try harness.coordinator.removeLocalToken(for: " Me@Gmail.com "))

            XCTAssertNil(try harness.secrets.value(for: key), "inspect the raw entry, not just the decoded token")
            XCTAssertEqual(try harness.store.loadToken(for: "other@gmail.com"), otherToken)
        }
        XCTAssertNil(try harness.coordinator.removeLocalToken(for: "me@gmail.com"), "removal stays idempotent")
        XCTAssertTrue(harness.transport.requests.isEmpty)
    }

    func testDisconnectDeletesUndecodableEntryWithoutAttemptingRevocation() async throws {
        let harness = makeHarness()
        let key = SecretKey.gmailOAuthToken(email: "me@gmail.com")
        try harness.secrets.set("not-json", for: key)

        await harness.coordinator.disconnect("me@gmail.com")

        XCTAssertNil(try harness.secrets.value(for: key))
        XCTAssertTrue(harness.transport.requests.isEmpty, "revocation requires a decoded token")
    }

    func testDisconnectDeletesTokenAndRevokesRefreshToken() async throws {
        let harness = makeHarness(tokenJSON: "")
        try harness.store.saveToken(storedToken(expiresAt: now.addingTimeInterval(3600)), for: "me@gmail.com")

        await harness.coordinator.disconnect("me@gmail.com")

        XCTAssertFalse(harness.store.hasToken(for: "me@gmail.com"))
        XCTAssertEqual(harness.transport.lastURL, GoogleOAuth.revocationEndpoint)
        XCTAssertEqual(harness.transport.lastFields["token"], "rt")
    }

    func testDisconnectStillDeletesLocallyWhenRevocationFails() async throws {
        let harness = makeHarness()
        harness.transport.error = URLError(.notConnectedToInternet)
        try harness.store.saveToken(storedToken(expiresAt: now.addingTimeInterval(3600)), for: "me@gmail.com")

        await harness.coordinator.disconnect("me@gmail.com")

        XCTAssertFalse(harness.store.hasToken(for: "me@gmail.com"))
    }

    // MARK: - Messages

    func testFailureMessagesNeverMentionAppPasswordsExceptTheUnconfiguredFallback() {
        let errors: [Error] = [
            GmailAuthError.reauthorizationRequired, GmailAuthError.missingAccountEmail,
            OAuthError.redirectTimedOut, OAuthError.stateMismatch, OAuthError.missingRefreshToken
        ]
        for error in errors {
            XCTAssertFalse(GmailAuthCoordinator.message(for: error).contains("app password"), "\(error)")
        }
        XCTAssertTrue(GmailAuthCoordinator.message(for: GmailAuthError.notConfigured).contains("app password"))
    }

    // MARK: - Helpers

    private func assertThrows<E: Error & Equatable>(
        _ expression: @autoclosure () async throws -> some Any,
        _ expected: E,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }
}

// MARK: - Fakes

final class FakeRedirectListener: RedirectListener {
    private let redirectURI: String
    private let params: [String: String]
    private let waitError: Error?
    private(set) var stopped = false
    private(set) var requestedTimeout: TimeInterval?

    init(redirectURI: String, params: [String: String], waitError: Error? = nil) {
        self.redirectURI = redirectURI
        self.params = params
        self.waitError = waitError
    }

    func start() async throws -> String { redirectURI }
    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        requestedTimeout = timeout
        if let waitError {
            throw waitError
        }
        return params
    }
    func stop() { stopped = true }
}

final class SpyBrowser: BrowserOpening {
    private(set) var openedURL: URL?
    func open(_ url: URL) { openedURL = url }
}
