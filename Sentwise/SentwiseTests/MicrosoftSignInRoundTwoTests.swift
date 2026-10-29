import SentwiseMail
import XCTest
@testable import Sentwise

private struct TableMXResolver: MXRecordResolving {
    let table: [String: [String]]
    func records(for domain: String) async throws -> [String] { table[domain] ?? [] }
}

/// Microsoft sign-in review fixes (item 31, PR 136 Codex round 1). Scripted
/// transports and listeners only; no network.
@MainActor
final class MicrosoftSignInRoundTwoTests: XCTestCase {
    private let state = "FIXED-STATE"
    private let clientID = "11111111-2222-3333-4444-555555555555"
    private let address = "me@outlook.com"

    private func coordinator(store: GmailAuthStore, listener: RedirectListener) -> GmailAuthCoordinator {
        let scope = MicrosoftOAuth.scopes.joined(separator: " ")
        let token = MicrosoftSignInTests.idToken(address: address, tenant: MicrosoftOAuth.consumerTenantID)
        let body = """
        {"access_token":"fresh-at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer",\
        "scope":"\(scope)","id_token":"\(token)"}
        """
        return GmailAuthCoordinator(
            client: OAuthProviderConfiguration.microsoft(clientID: clientID),
            store: store,
            tokenService: OAuthTokenService(transport: FakeTransport(response: HTTPResponse(statusCode: 200, body: Data(body.utf8)))),
            makeListener: { listener },
            browser: SpyBrowser(),
            makeState: { self.state }
        )
    }

    private func makeApp(
        secrets: InMemorySecretStore = InMemorySecretStore(),
        verify: Result<Void, MailError> = .success(()),
        probe: Result<Void, Error> = .success(())
    ) -> (AppState, FakeAppMailProvider, GmailAuthStore) {
        let provider = FakeAppMailProvider(result: verify)
        provider.probeResult = probe
        let app = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            reachability: FakeReachabilityMonitor(isOnline: true, hasCurrentPath: false)
        )
        let store = GmailAuthStore(secrets: secrets, keychainPrefix: OAuthProviderConfiguration.microsoftKeychainPrefix)
        return (app, provider, store)
    }

    private func connectedApp(
        verify: Result<Void, MailError> = .success(())
    ) async -> (AppState, FakeAppMailProvider, GmailAuthStore, InMemorySecretStore) {
        let secrets = InMemorySecretStore()
        let (app, provider, store) = makeApp(secrets: secrets, verify: verify)
        let listener = FakeRedirectListener(redirectURI: "http://localhost:9999", params: ["code": "code", "state": state])
        app.microsoftMailAuth.install(coordinator(store: store, listener: listener))
        let connected = await app.connectWithMicrosoft()
        XCTAssertTrue(connected)
        return (app, provider, store, secrets)
    }

    private func staleToken() -> OAuthToken {
        OAuthToken(accessToken: "stale", refreshToken: "rt", expiresAt: .distantPast,
                   scope: MicrosoftOAuth.scopes.joined(separator: " "), tokenType: "Bearer")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 1: removal during a Microsoft sign-in

    func testRemovingTheMailboxWhileTheMicrosoftBrowserIsOpenRejectsTheCallback() async throws {
        let (app, _, store, secrets) = await connectedApp()
        let account = try XCTUnwrap(app.savedAccounts.first)
        let gated = GatedRedirectListener(redirectURI: "http://localhost:9999")
        app.microsoftMailAuth.install(coordinator(store: store, listener: gated))

        let reauth = Task { await app.connectWithMicrosoft() }
        await fulfillment(of: [gated.didStartWaiting], timeout: 2)
        app.removeSavedAccount(account)
        gated.release(["code": "code", "state": state])
        let connected = await reauth.value

        XCTAssertFalse(connected)
        XCTAssertTrue(app.savedAccounts.isEmpty, "a late Microsoft callback never restores the removed mailbox")
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertNil(try secrets.value(for: .mailAppPassword(email: address)))
        try await waitUntil { !store.hasToken(for: "me@outlook.com") }
    }

    // MARK: - 2: cleanup routes through the account's provider

    func testDisconnectAndSwitchTakeTheMicrosoftTokenAndRollBackRestoresIt() async throws {
        let (app, _, store, _) = await connectedApp()
        XCTAssertTrue(store.hasToken(for: address))

        let removal = try XCTUnwrap(app.takeGoogleTokenForDisconnect(email: address, messageSurface: .shared))
        XCTAssertNotNil(removal.microsoftToken)
        XCTAssertFalse(store.hasToken(for: address))
        app.rollBack(removal)
        XCTAssertTrue(store.hasToken(for: address))

        let switched = try XCTUnwrap(app.takeGoogleTokenForSwitch(
            email: address, previousSecret: MicrosoftMailCredential.marker,
            newSecret: "app-password", messageSurface: .shared
        ))
        XCTAssertNotNil(switched.microsoftToken)
        XCTAssertFalse(store.hasToken(for: address))
    }

    func testRemovalDeletesTheMicrosoftTokenInABuildWithoutAClientID() throws {
        let secrets = InMemorySecretStore()
        let (app, _, store) = makeApp(secrets: secrets)
        XCTAssertFalse(app.isMicrosoftSignInAvailable)
        try store.saveToken(staleToken(), for: address)

        let removal = try app.removeGoogleTokenForAccountRemoval(address)

        XCTAssertNotNil(removal.microsoftToken)
        XCTAssertFalse(store.hasToken(for: address), "no refresh token outlives the account")
        app.restoreGoogleTokenAfterFailedRemoval(removal)
        XCTAssertTrue(store.hasToken(for: address))
    }

    // MARK: - 3: Microsoft 365 custom domains

    func testMXDetectedMicrosoft365DomainShowsTheConfiguredMicrosoftOption() async {
        let (app, _, _, _) = await connectedApp()
        app.microsoft365MXDetector = Microsoft365MXDetector(
            resolver: TableMXResolver(table: ["contoso.com": ["contoso-com.mail.protection.outlook.com."]])
        )
        let hosted = await app.isMicrosoft365Hosted(email: "pat@contoso.com")
        let other = await app.isMicrosoft365Hosted(email: "pat@acme.io")
        XCTAssertTrue(hosted)
        XCTAssertFalse(other)

        let hidden = MailConnectLayout.make(email: "pat@contoso.com", host: "", isGoogleAvailable: true, isMicrosoftConfigured: true)
        XCTAssertFalse(hidden.showsMicrosoft)
        let shown = MailConnectLayout.make(
            email: "pat@contoso.com", host: "", isGoogleAvailable: true, isMicrosoftConfigured: true, isMicrosoft365Detected: true
        )
        XCTAssertTrue(shown.showsMicrosoft)
        let unconfigured = MailConnectLayout.make(
            email: "pat@contoso.com", host: "", isGoogleAvailable: true, isMicrosoftConfigured: false, isMicrosoft365Detected: true
        )
        XCTAssertFalse(unconfigured.showsMicrosoft)
    }

    // MARK: - 4: watcher resumes after Microsoft reauthentication

    func testMicrosoftReauthenticationResumesTheAuthPausedWatcher() async {
        let (app, _, _, _) = await connectedApp()
        app.llmProviderKind = .anthropic
        app.isLLMConnected = true
        app.startWatching()
        defer { app.stopWatching() }
        XCTAssertEqual(app.watchStatus, .watching)
        app.handlePollFetchFailure(MailError.authenticationFailed(MicrosoftMailCredential.reauthorizationDetail))
        XCTAssertEqual(app.watchStatus, .paused)
        XCTAssertTrue(app.resumeWatchingAfterGoogleReauth)

        let connected = await app.connectWithMicrosoft(loginHint: app.mailEmail, requireHintMatch: true)

        XCTAssertTrue(connected)
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertNil(app.watchError)
        XCTAssertFalse(app.resumeWatchingAfterGoogleReauth)
    }

    // MARK: - 5: provider-aware recovery messages

    private func decorator(rejecting base: MailError?, token: OAuthToken, status: Int = 200, body: String = "{}")
        throws -> (GoogleOAuthMailProvider, GoogleMailAuthService) {
        let store = GmailAuthStore(secrets: InMemorySecretStore(), keychainPrefix: OAuthProviderConfiguration.microsoftKeychainPrefix)
        try store.saveToken(token, for: address)
        let transport = FakeTransport(response: HTTPResponse(statusCode: status, body: Data(body.utf8)))
        let auth = GoogleMailAuthService(
            coordinator: GmailAuthCoordinator(
                client: OAuthProviderConfiguration.microsoft(clientID: clientID),
                store: store, tokenService: OAuthTokenService(transport: transport)
            ),
            credentialMarker: MicrosoftMailCredential.marker
        )
        let fake = FakeAppMailProvider(result: base.map { .failure($0) } ?? .success(()))
        return (GoogleOAuthMailProvider(base: fake, auth: auth), auth)
    }

    func testRevokedMicrosoftRefreshTokenAsksForMicrosoftNotGoogle() async throws {
        let (provider, _) = try decorator(rejecting: nil, token: staleToken(), status: 400, body: #"{"error":"invalid_grant"}"#)
        do {
            try await provider.verifyConnection(MicrosoftMailCredential.credentials(email: address, tenantID: nil))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? MailError, .authenticationFailed(MicrosoftMailCredential.reauthorizationDetail))
            XCTAssertFalse(AppState.message(for: error).contains("Google"))
            XCTAssertTrue(AppState.message(for: error).contains("Microsoft"))
        }
    }

    func testServerRejectionOfAMicrosoftTokenNamesOutlookNotGmail() async throws {
        let fresh = OAuthToken(accessToken: "at", refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600),
                               scope: MicrosoftOAuth.scopes.joined(separator: " "), tokenType: "Bearer")
        let (provider, _) = try decorator(rejecting: .authenticationFailed("AUTHENTICATE failed"), token: fresh)
        do {
            try await provider.verifyConnection(MicrosoftMailCredential.credentials(email: address, tenantID: nil))
            XCTFail("expected a failure")
        } catch {
            let message = AppState.message(for: error)
            XCTAssertTrue(message.contains("Outlook"), message)
            XCTAssertFalse(message.contains("Gmail") || message.contains("Google"), message)
            XCTAssertFalse(message.hasPrefix("Sign-in failed — check your email and app password"), message)
        }
    }

    // MARK: - 6: IMAP disabled is classified from the raw failure

    func testRawIMAPAuthFailureOnAFreshMicrosoftTokenBecomesProtocolDisabled() async {
        let (app, provider, _) = makeApp(verify: .failure(.authenticationFailed("LOGIN failed")))
        let listener = FakeRedirectListener(redirectURI: "http://localhost:9999", params: ["code": "code", "state": state])
        let secretsStore = GmailAuthStore(secrets: app.secrets, keychainPrefix: OAuthProviderConfiguration.microsoftKeychainPrefix)
        app.microsoftMailAuth.install(coordinator(store: secretsStore, listener: listener))

        let connected = await app.connectWithMicrosoft()

        XCTAssertFalse(connected)
        XCTAssertEqual(provider.probeCallCount, 0)
        XCTAssertEqual(app.connectionError, MicrosoftSignInCopy.protocolDisabledMessage(.imap))
        XCTAssertFalse(secretsStore.hasToken(for: address))
    }

    // MARK: - 7: protocol-disabled keeps the admin-note action

    func testSMTPProbeFailureKeepsTheProtocolFailureAndOffersTheAdminNote() async {
        let secrets = InMemorySecretStore()
        let (app, _, store) = makeApp(secrets: secrets, probe: .failure(MailError.mailboxProtocolDisabled(.smtp, "535 5.7.139")))
        let listener = FakeRedirectListener(redirectURI: "http://localhost:9999", params: ["code": "code", "state": state])
        app.microsoftMailAuth.install(coordinator(store: store, listener: listener))

        let connected = await app.connectWithMicrosoft()

        XCTAssertFalse(connected)
        XCTAssertEqual(app.microsoftSignInViewState(), .protocolDisabled(.smtp))
        XCTAssertEqual(app.microsoftMailAuth.adminApproval?.address, address)
        XCTAssertEqual(app.microsoftMailAuth.adminApproval?.protocolDisabled, .smtp)
        let note = MicrosoftAdminNote.text(reason: .protocolDisabled(.smtp), clientID: clientID, address: address)
        XCTAssertFalse(note.isEmpty)
        app.chooseAnotherMicrosoftAccount()
        XCTAssertNil(app.microsoftMailAuth.adminApproval)
    }
}
