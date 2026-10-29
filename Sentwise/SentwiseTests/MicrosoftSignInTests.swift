import SentwiseMail
import XCTest
@testable import Sentwise

/// "Sign in with Microsoft" connect, adoption and the SMTP AUTH probe
/// (item 31, T31-5 and T31-7). Scripted transports only; no network.
@MainActor
final class MicrosoftSignInTests: XCTestCase {
    private let state = "FIXED-STATE"
    private let clientID = "11111111-2222-3333-4444-555555555555"
    private let workTenant = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    struct Harness {
        let appState: AppState
        let provider: FakeAppMailProvider
        let secrets: InMemorySecretStore
        let store: GmailAuthStore
    }

    static func idToken(address: String, tenant: String, claim: String = "preferred_username") -> String {
        let payload: [String: Any] = ["iss": "https://login.microsoftonline.com/\(tenant)/v2.0", claim: address, "tid": tenant]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return "eyJhbGciOiJSUzI1NiJ9.\(data.base64URLEncodedString()).sig"
    }

    private func makeHarness(
        verify: Result<Void, MailError> = .success(()),
        probe: Result<Void, Error> = .success(()),
        address: String = "me@outlook.com",
        tenant: String = MicrosoftOAuth.consumerTenantID,
        configured: Bool = true,
        waitParams: [String: String]? = nil
    ) -> Harness {
        let secrets = InMemorySecretStore()
        let provider = FakeAppMailProvider(result: verify)
        provider.probeResult = probe
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            reachability: FakeReachabilityMonitor(isOnline: true, hasCurrentPath: false)
        )
        let store = GmailAuthStore(secrets: secrets, keychainPrefix: OAuthProviderConfiguration.microsoftKeychainPrefix)
        let scope = MicrosoftOAuth.scopes.joined(separator: " ")
        let exchange = """
        {"access_token":"fresh-at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer",\
        "scope":"\(scope)","id_token":"\(Self.idToken(address: address, tenant: tenant))"}
        """
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data(exchange.utf8)))
        if configured {
            let listener = FakeRedirectListener(
                redirectURI: "http://localhost:9999",
                params: waitParams ?? ["code": "code", "state": state]
            )
            appState.microsoftMailAuth.install(GmailAuthCoordinator(
                client: OAuthProviderConfiguration.microsoft(clientID: clientID),
                store: store,
                tokenService: OAuthTokenService(transport: transport),
                makeListener: { listener },
                browser: SpyBrowser(),
                makeState: { self.state }
            ))
        }
        return Harness(appState: appState, provider: provider, secrets: secrets, store: store)
    }

    // MARK: - Adoption (T31-5)

    func testPersonalAccountAdoptsAddressAndTenantAndUsesPersonalSMTPHost() async throws {
        let harness = makeHarness()
        let connected = await harness.appState.connectWithMicrosoft()
        XCTAssertTrue(connected)
        XCTAssertTrue(harness.appState.isAccountConnected)
        XCTAssertEqual(harness.appState.mailEmail, "me@outlook.com")
        let used = try XCTUnwrap(harness.provider.lastProbeCredentials)
        XCTAssertEqual(used.email, "me@outlook.com")
        XCTAssertEqual(used.smtpHost, MicrosoftOAuth.personalSMTPHost)
        XCTAssertEqual(used.host, MicrosoftOAuth.imapHost)
        XCTAssertEqual(used.appPassword, MicrosoftMailCredential.marker)
        XCTAssertTrue(harness.store.hasToken(for: "me@outlook.com"))
    }

    func testWorkAccountUsesWorkSMTPHostFromTenantID() async throws {
        let harness = makeHarness(address: "rep@contoso.com", tenant: workTenant)
        let connected = await harness.appState.connectWithMicrosoft()
        XCTAssertTrue(connected)
        XCTAssertEqual(harness.provider.lastProbeCredentials?.smtpHost, MicrosoftOAuth.workSMTPHost)
        XCTAssertEqual(harness.appState.mailEmail, "rep@contoso.com")
    }

    func testSMTPHostPicksPersonalOnlyForConsumerTenant() {
        XCTAssertEqual(MicrosoftOAuth.smtpHost(forTenant: MicrosoftOAuth.consumerTenantID), MicrosoftOAuth.personalSMTPHost)
        XCTAssertEqual(MicrosoftOAuth.smtpHost(forTenant: workTenant), MicrosoftOAuth.workSMTPHost)
        XCTAssertEqual(MicrosoftOAuth.smtpHost(forTenant: nil), MicrosoftOAuth.workSMTPHost)
    }

    func testIDTokenAddressFallsBackToPreferredUsernameAndReadsTenant() {
        let token = Self.idToken(address: "rep@contoso.com", tenant: workTenant)
        XCTAssertEqual(GoogleIDToken.email(fromIDToken: token), "rep@contoso.com")
        XCTAssertEqual(GoogleIDToken.tenantID(fromIDToken: token), workTenant)
        let viaEmail = Self.idToken(address: "me@outlook.com", tenant: MicrosoftOAuth.consumerTenantID, claim: "email")
        XCTAssertEqual(GoogleIDToken.email(fromIDToken: viaEmail), "me@outlook.com")
    }

    // MARK: - Probe (T31-7)

    func testSMTPAuthDisabledAdoptsNothingAndDeletesTheStoredToken() async throws {
        let harness = makeHarness(probe: .failure(MailError.mailboxProtocolDisabled(.smtp, "535 5.7.139")))
        let connected = await harness.appState.connectWithMicrosoft()
        XCTAssertFalse(connected)
        XCTAssertFalse(harness.appState.isAccountConnected)
        XCTAssertEqual(harness.provider.probeCallCount, 1)
        XCTAssertFalse(harness.store.hasToken(for: "me@outlook.com"), "no half-added account keeps a token")
        XCTAssertNil(try harness.secrets.value(for: .mailAppPassword(email: "me@outlook.com")))
        XCTAssertEqual(harness.appState.connectionError, MicrosoftSignInCopy.protocolDisabledMessage(.smtp))
    }

    func testIMAPDisabledAdoptsNothingDeletesTokenAndSkipsTheSMTPProbe() async throws {
        let harness = makeHarness(verify: .failure(.authenticationFailed("LOGIN failed")))
        let connected = await harness.appState.connectWithMicrosoft()
        XCTAssertFalse(connected)
        XCTAssertFalse(harness.appState.isAccountConnected)
        XCTAssertEqual(harness.provider.probeCallCount, 0)
        XCTAssertFalse(harness.store.hasToken(for: "me@outlook.com"))
        XCTAssertEqual(harness.appState.connectionError, MicrosoftSignInCopy.protocolDisabledMessage(.imap))
    }

    func testProbeDoesNotRunForAppPasswordConnections() async {
        let harness = makeHarness()
        let credentials = MailAccountCredentials(
            email: "me@yahoo.com", appPassword: "app-password", host: "imap.mail.yahoo.com", port: 993
        )
        _ = await harness.appState.testConnection(
            with: credentials, messageSurface: .shared, attempt: harness.appState.beginMailConnectionAttempt()
        ) { _ in true }
        XCTAssertEqual(harness.provider.probeCallCount, 0)
    }

    // MARK: - Consent required and not configured

    func testAdminConsentRequiredSetsApprovalStateAndAdminCopy() async {
        let harness = makeHarness(waitParams: ["error": "consent_required", "error_description": "AADSTS65001", "state": state])
        let connected = await harness.appState.connectWithMicrosoft(loginHint: "rep@contoso.com")
        XCTAssertFalse(connected)
        XCTAssertEqual(harness.appState.microsoftSignInViewState(), .consentRequired)
        XCTAssertEqual(harness.appState.microsoftMailAuth.adminApproval?.address, "rep@contoso.com")
        XCTAssertEqual(harness.appState.connectionError, MicrosoftSignInCopy.adminApproval)
        harness.appState.chooseAnotherMicrosoftAccount()
        XCTAssertNil(harness.appState.microsoftMailAuth.adminApproval)
        XCTAssertNil(harness.appState.connectionError)
    }

    func testNotConfiguredBuildShowsCleanStateAndConnectsNothing() async {
        let harness = makeHarness(configured: false)
        XCTAssertFalse(harness.appState.isMicrosoftSignInAvailable)
        XCTAssertEqual(harness.appState.microsoftSignInViewState(), .notConfigured)
        let connected = await harness.appState.connectWithMicrosoft()
        XCTAssertFalse(connected)
        XCTAssertEqual(harness.appState.connectionError, MicrosoftSignInCopy.notConfigured)
    }
}

/// Pure view-state mapping for the Microsoft block and the connect chooser.
final class MicrosoftSignInViewStateTests: XCTestCase {
    private func make(
        configured: Bool = true, phase: GmailAuthPhase = .idle, verifying: Bool = false,
        reauth: String? = nil, failure: Error? = nil
    ) -> MicrosoftSignInViewState {
        MicrosoftSignInViewState.make(
            isConfigured: configured, phase: phase, isVerifying: verifying,
            reauthenticateAddress: reauth, failure: failure
        )
    }

    func testNotConfiguredWinsOverEverything() {
        XCTAssertEqual(make(configured: false, phase: .awaitingBrowser, reauth: "a@b.com"), .notConfigured)
    }

    func testConfiguredPhasesMapToWaitingAndChecking() {
        XCTAssertEqual(make(phase: .awaitingBrowser), .waitingForBrowser)
        XCTAssertEqual(make(phase: .exchangingCode), .checking)
        XCTAssertEqual(make(verifying: true), .checking)
    }

    func testReauthenticationCarriesTheSavedAddress() {
        XCTAssertEqual(make(reauth: "me@outlook.com"), .reauthenticate(address: "me@outlook.com"))
    }

    func testIdleConfiguredIsReady() {
        guard case .ready = make() else { return XCTFail("expected ready") }
    }

    func testChooserOffersMicrosoftForMicrosoftAddressesAndHostsWhenConfigured() {
        let layout = MailConnectLayout.make(
            email: "me@outlook.com", host: "", isGoogleAvailable: true, isMicrosoftConfigured: true
        )
        XCTAssertTrue(layout.showsMicrosoft)
        XCTAssertFalse(layout.showsGoogle)
        XCTAssertFalse(layout.appPasswordExpanded)
        let byHost = MailConnectLayout.make(
            email: "rep@acme-corp.com", host: "outlook.office365.com", isGoogleAvailable: true, isMicrosoftConfigured: true
        )
        XCTAssertTrue(byHost.showsMicrosoft)
    }

    func testChooserShowsNotConfiguredNoteAndExpandsAppPasswordWhenNoClientID() {
        let layout = MailConnectLayout.make(
            email: "me@hotmail.com", host: "", isGoogleAvailable: true, isMicrosoftConfigured: false
        )
        XCTAssertFalse(layout.showsMicrosoft)
        XCTAssertTrue(layout.showsMicrosoftNotConfigured)
        XCTAssertTrue(layout.appPasswordExpanded)
    }

    func testGmailKeepsGoogleLeadAndNoMicrosoft() {
        let layout = MailConnectLayout.make(
            email: "me@gmail.com", host: "", isGoogleAvailable: true, isMicrosoftConfigured: true
        )
        XCTAssertTrue(layout.showsGoogle)
        XCTAssertFalse(layout.showsMicrosoft)
        XCTAssertFalse(layout.showsMicrosoftNotConfigured)
    }
}
