import SentwiseMail
import XCTest
@testable import Sentwise

/// "Sign in with Google" wiring (item 104): the per-build switch, the connect
/// method selection (Google vs. app-password fallback), the XOAUTH2 provider
/// decorator, and the AppState connect / disconnect flow.
@MainActor
final class GoogleSignInTests: XCTestCase {

    private let state = "FIXED-STATE"
    private let clientID = "1234-abc.apps.googleusercontent.com"

    // MARK: - Build configuration switch

    func testBundledClientIsOffWhenUnsetUnexpandedOrPlaceholder() {
        let key = GoogleOAuthClientConfiguration.clientIDInfoKey
        XCTAssertNil(GoogleOAuthClientConfiguration.bundled(infoDictionary: nil))
        XCTAssertNil(GoogleOAuthClientConfiguration.bundled(infoDictionary: [:]))
        XCTAssertNil(GoogleOAuthClientConfiguration.bundled(infoDictionary: [key: ""]))
        XCTAssertNil(GoogleOAuthClientConfiguration.bundled(infoDictionary: [key: "$(SENTWISE_GOOGLE_CLIENT_ID)"]))
        XCTAssertNil(GoogleOAuthClientConfiguration.bundled(
            infoDictionary: [key: "YOUR_CLIENT_ID.apps.googleusercontent.com"]
        ))
        XCTAssertNil(GoogleOAuthClientConfiguration.bundled(infoDictionary: [key: "not-a-google-client-id"]))
        XCTAssertNil(GoogleOAuthClientConfiguration.bundled(infoDictionary: [key: ".apps.googleusercontent.com"]))
    }

    func testBundledClientReadsIDAndOptionalSecret() {
        let idKey = GoogleOAuthClientConfiguration.clientIDInfoKey
        let secretKey = GoogleOAuthClientConfiguration.clientSecretInfoKey

        let withSecret = GoogleOAuthClientConfiguration.bundled(infoDictionary: [idKey: " \(clientID) ", secretKey: "GOCSPX-s"])
        XCTAssertEqual(withSecret, OAuthProviderConfiguration.google(clientID: clientID, clientSecret: "GOCSPX-s"))

        let unexpandedSecret = GoogleOAuthClientConfiguration.bundled(
            infoDictionary: [idKey: clientID, secretKey: "$(SENTWISE_GOOGLE_CLIENT_SECRET)"]
        )
        XCTAssertEqual(unexpandedSecret?.clientID, clientID)
        XCTAssertNil(unexpandedSecret?.clientSecret)
    }

    func testCommittedConfigurationShipsTheFeatureSwitchedOff() throws {
        // The committed xcconfig carries no client ID, so a CI/fork build (and
        // this test host) never offers Google sign-in unless one is supplied.
        let infoValue = Bundle.main.object(forInfoDictionaryKey: GoogleOAuthClientConfiguration.clientIDInfoKey) as? String
        if let infoValue, GoogleOAuthClientConfiguration.isUsableClientID(infoValue) {
            throw XCTSkip("This build was configured with a real client ID (local override).")
        }
        XCTAssertNil(GoogleOAuthClientConfiguration.bundled())
    }

    // MARK: - Connect method selection (fallback)

    func testGoogleSignInLeadsForGmailWorkspaceAndBlankForms() {
        let pick = { MailConnectMethod.recommended(email: $0, host: $1, isGoogleSignInAvailable: true) }
        XCTAssertEqual(pick("", ""), .googleSignIn)
        XCTAssertEqual(pick("", "imap.gmail.com"), .googleSignIn)
        XCTAssertEqual(pick("me@gmail.com", "imap.gmail.com"), .googleSignIn)
        XCTAssertEqual(pick("me@googlemail.com", ""), .googleSignIn)
        XCTAssertEqual(pick("rep@acme-corp.com", "imap.gmail.com"), .googleSignIn, "custom domain may be Workspace")
    }

    func testAppPasswordIsTheFallbackForOtherProvidersHostsAndUnconfiguredBuilds() {
        let pick = { MailConnectMethod.recommended(email: $0, host: $1, isGoogleSignInAvailable: true) }
        XCTAssertEqual(pick("me@yahoo.com", "imap.mail.yahoo.com"), .appPassword)
        XCTAssertEqual(pick("me@icloud.com", ""), .appPassword)
        XCTAssertEqual(pick("rep@acme-corp.com", "mail.acme-corp.com"), .appPassword)
        XCTAssertEqual(pick("me@gmail.com", "imap.proxy.example"), .appPassword)
        XCTAssertEqual(
            MailConnectMethod.recommended(email: "me@gmail.com", host: "imap.gmail.com", isGoogleSignInAvailable: false),
            .appPassword
        )
    }

    // MARK: - Provider decorator

    struct Harness {
        let appState: AppState
        let provider: FakeAppMailProvider
        let secrets: InMemorySecretStore
        let store: GmailAuthStore
        let transport: FakeTransport
        let browser: SpyBrowser
    }

    func makeHarness(
        verify: Result<Void, MailError> = .success(()),
        idEmail: String = "me@gmail.com",
        waitError: Error? = nil,
        installCoordinator: Bool = true
    ) -> Harness {
        let secrets = InMemorySecretStore()
        let provider = FakeAppMailProvider(result: verify)
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            reachability: FakeReachabilityMonitor(isOnline: true, hasCurrentPath: false)
        )
        let store = GmailAuthStore(secrets: secrets)
        let exchange = """
        {"access_token":"fresh-at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer",\
        "scope":"https://mail.google.com/ openid","id_token":"\(GmailAuthCoordinatorTests.idToken(email: idEmail))"}
        """
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data(exchange.utf8)))
        let browser = SpyBrowser()
        if installCoordinator {
            let listener = FakeRedirectListener(
                redirectURI: "http://127.0.0.1:9999",
                params: ["code": "code", "state": state],
                waitError: waitError
            )
            appState.googleMailAuth.install(GmailAuthCoordinator(
                client: OAuthProviderConfiguration.google(clientID: clientID),
                store: store,
                tokenService: OAuthTokenService(transport: transport),
                makeListener: { listener },
                browser: browser,
                makeState: { self.state }
            ))
        } else {
            appState.googleMailAuth.install(nil)
        }
        return Harness(appState: appState, provider: provider, secrets: secrets,
                       store: store, transport: transport, browser: browser)
    }

    func seedToken(_ store: GmailAuthStore, email: String = "me@gmail.com", expired: Bool = false) throws {
        try store.saveToken(OAuthToken(
            accessToken: "stored-at",
            refreshToken: "rt",
            expiresAt: expired ? .distantPast : .distantFuture,
            scope: GoogleOAuth.mailScope,
            tokenType: "Bearer"
        ), for: email)
    }

    func testDecoratorPassesAppPasswordCredentialsThrough() async throws {
        let harness = makeHarness()
        let credentials = MailAccountCredentials(email: "me@yahoo.com", appPassword: "pw", host: "imap.mail.yahoo.com")
        try await harness.appState.mailProvider.verifyConnection(credentials)
        XCTAssertEqual(harness.provider.lastCredentials, credentials)
        XCTAssertEqual(harness.provider.lastCredentials?.authentication, .password("pw"))
    }

    func testDecoratorSwapsTheMarkerForAnXOAuth2AccessToken() async throws {
        let harness = makeHarness()
        try seedToken(harness.store)

        try await harness.appState.mailProvider.verifyConnection(GoogleMailCredential.credentials(email: "me@gmail.com"))

        XCTAssertEqual(harness.provider.lastCredentials?.authentication, .xoauth2(accessToken: "stored-at"))
        XCTAssertEqual(harness.provider.lastCredentials?.host, "imap.gmail.com")
    }

    func testDecoratorRefreshesAnExpiredTokenBeforeSending() async throws {
        let harness = makeHarness()
        try seedToken(harness.store, expired: true)
        harness.transport.response = HTTPResponse(statusCode: 200, body: Data(
            #"{"access_token":"refreshed","expires_in":3600,"scope":"https://mail.google.com/"}"#.utf8
        ))

        try await harness.appState.mailProvider.sendMessage(
            GoogleMailCredential.credentials(email: "me@gmail.com"),
            rfc822: Data("x".utf8),
            envelope: SMTPEnvelope(sender: "me@gmail.com", recipients: ["a@example.com"])
        )

        XCTAssertEqual(harness.provider.lastSendCredentials?.authentication, .xoauth2(accessToken: "refreshed"))
    }

    func testRevokedGrantSurfacesAsGoogleReauthorizationNotAppPasswordCopy() async throws {
        let harness = makeHarness()
        try seedToken(harness.store, expired: true)
        harness.transport.response = HTTPResponse(statusCode: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))

        do {
            try await harness.appState.mailProvider.verifyConnection(GoogleMailCredential.credentials(email: "me@gmail.com"))
            XCTFail("expected an auth failure")
        } catch {
            XCTAssertEqual(error as? MailError, .authenticationFailed(GoogleMailCredential.reauthorizationDetail))
            XCTAssertEqual(ResilienceClassifier.classify(error), .authentication)
            let message = AppState.message(for: error)
            XCTAssertFalse(message.contains("app password"), message)
            XCTAssertTrue(message.contains("sign in with Google again"), message)
        }
        XCTAssertNil(harness.provider.lastCredentials, "no IMAP session without a usable token")
    }

    func testTokenEndpointOutageIsTransient() async throws {
        let harness = makeHarness()
        try seedToken(harness.store, expired: true)
        harness.transport.error = URLError(.notConnectedToInternet)

        do {
            try await harness.appState.mailProvider.verifyConnection(GoogleMailCredential.credentials(email: "me@gmail.com"))
            XCTFail("expected a failure")
        } catch {
            guard case .connectionFailed = error as? MailError else { return XCTFail("got \(error)") }
            XCTAssertEqual(ResilienceClassifier.classify(error), .transient)
        }
    }

    func testServerRejectionOfXOAuth2IsReworded() async throws {
        let harness = makeHarness(verify: .failure(.authenticationFailed("[AUTHENTICATIONFAILED] Invalid credentials")))
        try seedToken(harness.store)

        do {
            try await harness.appState.mailProvider.verifyConnection(GoogleMailCredential.credentials(email: "me@gmail.com"))
            XCTFail("expected a failure")
        } catch {
            let message = AppState.message(for: error)
            XCTAssertTrue(message.hasPrefix("Google sign-in was rejected by Gmail"), message)
            XCTAssertFalse(message.contains("app password"))
        }
    }

    // MARK: - AppState connect flow

    func testConnectWithGoogleAdoptsTheAuthorizedMailbox() async throws {
        let harness = makeHarness()

        let connected = await harness.appState.connectWithGoogle(loginHint: "me@gmail.com")

        XCTAssertTrue(connected)
        XCTAssertTrue(harness.appState.isAccountConnected)
        XCTAssertTrue(harness.appState.activeAccountUsesGoogleSignIn)
        XCTAssertEqual(harness.appState.mailEmail, "me@gmail.com")
        XCTAssertEqual(harness.appState.mailHost, "imap.gmail.com")
        XCTAssertEqual(harness.provider.lastCredentials?.authentication, .xoauth2(accessToken: "fresh-at"))
        XCTAssertEqual(try harness.secrets.value(for: .mailAppPassword(email: "me@gmail.com")), GoogleMailCredential.marker)
        XCTAssertTrue(harness.store.hasToken(for: "me@gmail.com"))
        XCTAssertTrue(harness.appState.savedAccountUsesGoogleSignIn("me@gmail.com"))
        XCTAssertEqual(harness.appState.savedAccounts.map(\.email), ["me@gmail.com"])
        XCTAssertNotNil(harness.browser.openedURL)
        XCTAssertNil(harness.appState.connectionError)
    }

    func testReauthorizationReplacesExpiredGrantWithoutDisconnectingMailbox() async throws {
        let harness = makeHarness()
        try seedToken(harness.store)
        let credentials = GoogleMailCredential.credentials(email: "me@gmail.com")
        let initiallyConnected = await harness.appState.testConnection(with: credentials)
        XCTAssertTrue(initiallyConnected)
        try seedToken(harness.store, expired: true)
        harness.appState.watchStatus = .paused
        harness.appState.connectionError = GoogleMailCredential.reauthorizationDetail

        let connected = await harness.appState.connectWithGoogle(
            loginHint: harness.appState.mailEmail, requireHintMatch: true, messageSurface: .settings
        )

        XCTAssertTrue(connected)
        XCTAssertTrue(harness.appState.activeAccountUsesGoogleSignIn)
        XCTAssertEqual(harness.appState.savedAccounts.map(\.email), ["me@gmail.com"])
        XCTAssertEqual(try harness.store.loadToken(for: "me@gmail.com")?.accessToken, "fresh-at")
        XCTAssertEqual(harness.provider.lastCredentials?.authentication, .xoauth2(accessToken: "fresh-at"))
        XCTAssertNil(harness.appState.connectionError(for: .settings))
    }

    func testReauthorizationRejectsDifferentGoogleAccountAndPreservesActiveGrant() async throws {
        let harness = makeHarness(idEmail: "other@gmail.com")
        try seedToken(harness.store)
        let credentials = GoogleMailCredential.credentials(email: "me@gmail.com")
        let initiallyConnected = await harness.appState.testConnection(with: credentials)
        XCTAssertTrue(initiallyConnected)

        let connected = await harness.appState.connectWithGoogle(
            loginHint: harness.appState.mailEmail, requireHintMatch: true, messageSurface: .settings
        )

        XCTAssertFalse(connected)
        XCTAssertTrue(harness.appState.activeAccountUsesGoogleSignIn)
        XCTAssertEqual(harness.appState.mailEmail, "me@gmail.com")
        XCTAssertEqual(try harness.store.loadToken(for: "me@gmail.com")?.accessToken, "stored-at")
        XCTAssertFalse(harness.store.hasToken(for: "other@gmail.com"))
        XCTAssertEqual(harness.appState.savedAccounts.map(\.email), ["me@gmail.com"])
        XCTAssertEqual(harness.appState.connectionError(for: .settings), GmailAuthCoordinator.message(
            for: GmailAuthError.accountMismatch(expected: "me@gmail.com", actual: "other@gmail.com")
        ))
    }

    func testConnectWithGoogleIsUnavailableWithoutABundledClient() async {
        let harness = makeHarness(installCoordinator: false)

        XCTAssertFalse(harness.appState.isGoogleSignInAvailable)
        XCTAssertEqual(harness.appState.recommendedConnectMethod(email: "me@gmail.com", host: "imap.gmail.com"), .appPassword)
        let connected = await harness.appState.connectWithGoogle()

        XCTAssertFalse(connected)
        XCTAssertNil(harness.browser.openedURL)
        XCTAssertEqual(harness.appState.connectionError, GmailAuthCoordinator.message(for: GmailAuthError.notConfigured))
    }

    func testFailedVerificationDropsTheNewGrantAndShowsNoAppPasswordGuidance() async throws {
        let harness = makeHarness(verify: .failure(.authenticationFailed("[ALERT] IMAP access is disabled for your domain")))

        let connected = await harness.appState.connectWithGoogle()

        XCTAssertFalse(connected)
        XCTAssertFalse(harness.appState.isAccountConnected)
        XCTAssertFalse(harness.store.hasToken(for: "me@gmail.com"), "an unconnected mailbox keeps no grant")
        XCTAssertNil(try harness.secrets.value(for: .mailAppPassword(email: "me@gmail.com")))
        XCTAssertNil(harness.appState.workspaceAuthGuidance(for: .shared))
        XCTAssertTrue(harness.appState.connectionError?.hasPrefix("Google sign-in was rejected") == true)
    }

    func testCanceledSignInIsQuiet() async {
        let harness = makeHarness(waitError: CancellationError())
        let connected = await harness.appState.connectWithGoogle()
        XCTAssertFalse(connected)
        XCTAssertNil(harness.appState.connectionError)
        XCTAssertEqual(harness.appState.googleMailAuth.phase, .idle)
    }

    func testConsentDeniedShowsMessageAndFailedPhase() async {
        let harness = makeHarness()
        harness.appState.googleMailAuth.install(GmailAuthCoordinator(
            client: OAuthProviderConfiguration.google(clientID: clientID),
            store: harness.store,
            tokenService: OAuthTokenService(transport: harness.transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["error": "access_denied", "state": self.state]) },
            browser: harness.browser,
            makeState: { self.state }
        ))

        let connected = await harness.appState.connectWithGoogle()

        XCTAssertFalse(connected)
        XCTAssertEqual(harness.appState.connectionError, "Google sign-in was canceled.")
        XCTAssertEqual(harness.appState.googleMailAuth.phase, .failed("Google sign-in was canceled."))
        harness.appState.googleMailAuth.clearFailure()
        XCTAssertEqual(harness.appState.googleMailAuth.phase, .idle)
    }

    func testDisconnectForgetsAndRevokesTheGoogleGrant() async throws {
        let harness = makeHarness()
        await harness.appState.connectWithGoogle()
        XCTAssertTrue(harness.store.hasToken(for: "me@gmail.com"))

        harness.appState.disconnectMail()

        XCTAssertFalse(harness.appState.isAccountConnected)
        try await waitUntil { !harness.store.hasToken(for: "me@gmail.com") }
        try await waitUntil { harness.transport.lastURL == GoogleOAuth.revocationEndpoint }
        XCTAssertEqual(harness.transport.lastFields["token"], "rt")
    }

    func testSwitchingTheMailboxToAnAppPasswordForgetsTheGoogleGrant() async throws {
        let harness = makeHarness()
        await harness.appState.connectWithGoogle()

        let connected = await harness.appState.testConnection(with: MailAccountCredentials(
            email: "me@gmail.com", appPassword: "abcdefghijklmnop", host: "imap.gmail.com", port: 993
        ))

        XCTAssertTrue(connected)
        XCTAssertFalse(harness.appState.activeAccountUsesGoogleSignIn)
        try await waitUntil { !harness.store.hasToken(for: "me@gmail.com") }
    }

    func testRemovingASavedGoogleAccountForgetsItsGrant() async throws {
        let harness = makeHarness()
        await harness.appState.connectWithGoogle()
        let account = try XCTUnwrap(harness.appState.savedAccounts.first)

        harness.appState.removeSavedAccount(account)

        try await waitUntil { !harness.store.hasToken(for: "me@gmail.com") }
        XCTAssertNil(try harness.secrets.value(for: .mailAppPassword(email: "me@gmail.com")))
    }

    // MARK: - Helpers

    private func waitUntil(
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

@MainActor
final class GoogleSignInOnboardingTests: XCTestCase {
    func testContinueHintMentionsGoogleOnlyWhenAvailable() {
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        appState.googleMailAuth.install(nil)
        XCTAssertEqual(appState.onboardingContinueBlockedReason(for: .connectAccount), "Run Test Connection to continue.")

        appState.googleMailAuth.install(GmailAuthCoordinator(
            client: OAuthProviderConfiguration.google(clientID: "1-a.apps.googleusercontent.com"),
            store: GmailAuthStore(secrets: InMemorySecretStore()),
            tokenService: OAuthTokenService(transport: FakeTransport(response: HTTPResponse(statusCode: 200, body: Data())))
        ))
        XCTAssertEqual(
            appState.onboardingContinueBlockedReason(for: .connectAccount),
            "Sign in with Google or run Test Connection to continue."
        )
    }
}
