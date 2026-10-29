import SentwiseMail
import XCTest
@testable import Sentwise

/// Codex round 2 (item 31): a saved account's SMTP overrides and discovered
/// folder names reach `MailAccountCredentials` on every construction path.
@MainActor
final class AccountTransportRoundTripTests: XCTestCase {

    private let starttls = SavedMailAccount(
        email: "me@outlook.com",
        host: "outlook.office365.com",
        port: 993,
        smtpHost: "smtp.office365.com",
        smtpPort: 587,
        smtpSecurity: SavedMailAccount.smtpSecuritySTARTTLS,
        authProvider: SavedMailAccount.authProviderPassword
    )

    private func makeApp(provider: FakeAppMailProvider = FakeAppMailProvider(result: .success(()))) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(settings: .default),
            secrets: InMemorySecretStore(),
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    func testSavedStartTLSAccountBuildsCredentialsWithExactValues() {
        let credentials = starttls.credentials(appPassword: "pw")
        XCTAssertEqual(credentials.smtpHost, "smtp.office365.com")
        XCTAssertEqual(credentials.smtpPort, 587)
        XCTAssertEqual(credentials.smtpSecurity, .startTLS)
    }

    func testSwitchReachesVerifyWithSMTPOverrides() async throws {
        let provider = FakeAppMailProvider(result: .success(()))
        let app = makeApp(provider: provider)
        try app.secrets.set("pw", for: .mailAppPassword(email: starttls.email))
        app.savedAccounts = [starttls]

        await app.switchToSavedAccount(starttls)

        let seen = try XCTUnwrap(provider.lastCredentials)
        XCTAssertEqual(seen.smtpHost, "smtp.office365.com")
        XCTAssertEqual(seen.smtpPort, 587)
        XCTAssertEqual(seen.smtpSecurity, .startTLS)
        // The focused credentials the sender uses keep them too.
        XCTAssertEqual(app.mailCredentials.smtpPort, 587)
        XCTAssertEqual(app.mailCredentials.smtpSecurity, .startTLS)
        XCTAssertEqual(app.mailCredentials.smtpHost, "smtp.office365.com")
    }

    func testNormalizationKeepsExplicitOverridesAndTrimsIdentity() async throws {
        let provider = FakeAppMailProvider(result: .success(()))
        let app = makeApp(provider: provider)
        let raw = MailAccountCredentials(
            email: " me@outlook.com ",
            appPassword: "pw",
            host: "outlook.office365.com ",
            port: 993,
            smtpHost: "smtp.office365.com",
            smtpPort: 587,
            smtpSecurity: .startTLS
        )
        _ = await app.testConnection(with: raw, messageSurface: .shared) { _ in true }
        let seen = try XCTUnwrap(provider.lastCredentials)
        XCTAssertEqual(seen.email, "me@outlook.com")
        XCTAssertEqual(seen.host, "outlook.office365.com")
        XCTAssertEqual(seen.smtpHost, "smtp.office365.com")
        XCTAssertEqual(seen.smtpPort, 587)
        XCTAssertEqual(seen.smtpSecurity, .startTLS)
        // And the verified overrides are remembered on the saved account.
        let saved = try XCTUnwrap(app.savedAccounts.first)
        XCTAssertEqual(saved.smtpPort, 587)
        XCTAssertEqual(saved.smtpSecurity, SavedMailAccount.smtpSecuritySTARTTLS)
        XCTAssertEqual(saved.smtpHost, "smtp.office365.com")
    }

    func testLegacyAccountWithoutOverridesDerivesOldDefaults() async throws {
        let legacy = SavedMailAccount(email: "old@example.com", host: "imap.example.com", port: 993)
        let provider = FakeAppMailProvider(result: .success(()))
        let app = makeApp(provider: provider)
        try app.secrets.set("pw", for: .mailAppPassword(email: legacy.email))
        app.savedAccounts = [legacy]

        await app.switchToSavedAccount(legacy)

        let seen = try XCTUnwrap(provider.lastCredentials)
        XCTAssertEqual(seen.smtpHost, "smtp.example.com")
        XCTAssertEqual(seen.smtpPort, 465)
        XCTAssertEqual(seen.smtpSecurity, .implicitTLS)
        let saved = try XCTUnwrap(app.savedAccounts.first)
        XCTAssertNil(saved.smtpHost)
        XCTAssertNil(saved.smtpPort)
        XCTAssertNil(saved.smtpSecurity)
        XCTAssertNil(saved.mailboxNaming)
    }

    func testDiscoveredNamingIsPersistedAndUsedByCredentials() async throws {
        var naming = MailboxNaming.microsoft
        naming.sent = "Elementos enviados"
        let provider = FakeAppMailProvider(result: .success(()))
        provider.discoveredNaming = naming
        let app = makeApp(provider: provider)
        app.mailEmail = "me@outlook.com"
        app.mailHost = "outlook.office365.com"
        app.mailPort = 993
        app.mailAppPassword = "pw"
        await app.testConnection()

        XCTAssertEqual(app.savedAccounts.first?.mailboxNaming?.sent, "Elementos enviados")
        XCTAssertEqual(app.mailCredentials.mailboxNaming.sent, "Elementos enviados")
        XCTAssertEqual(
            Mailbox.sent.imapName(using: app.mailCredentials.mailboxNaming), "Elementos enviados"
        )
    }

    func testBackgroundRuntimeCredentialsCarryTransport() {
        let runtime = ConnectedMailAccount(
            email: starttls.email, host: starttls.host, port: starttls.port,
            appPassword: "pw", savedAccount: starttls
        )
        XCTAssertEqual(runtime.credentials.smtpPort, 587)
        XCTAssertEqual(runtime.credentials.smtpSecurity, .startTLS)
    }

    func testSavedAccountDecodesWithoutMailboxNaming() throws {
        let json = #"{"email":"a@b.c","host":"imap.b.c","port":993}"#
        let decoded = try JSONDecoder().decode(SavedMailAccount.self, from: Data(json.utf8))
        XCTAssertNil(decoded.mailboxNaming)
    }

    func testAddAccountWithDiscoverySavesNamingAndStaleResultIsRejected() async throws {
        var naming = MailboxNaming.microsoft
        naming.sent = "Elementos enviados"
        let provider = FakeAppMailProvider(result: .success(()))
        provider.discoveredNaming = naming
        let app = makeApp(provider: provider)
        let submitted = MailAccountCredentials(email: "me@outlook.com", appPassword: "pw", host: "outlook.office365.com")
        let accepted = await app.testConnection(with: submitted, messageSurface: .settings) {
            var result = $0
            result.discoveredNaming = submitted.discoveredNaming
            return result == submitted
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(app.savedAccounts.first?.mailboxNaming?.sent, "Elementos enviados")

        let other = makeApp(provider: provider)
        let stale = await other.testConnection(with: submitted, messageSurface: .settings) { _ in false }
        XCTAssertFalse(stale)
        XCTAssertTrue(other.savedAccounts.isEmpty)
    }

    func testReverifyWithDefaultsClearsStoredOverrides() async throws {
        let provider = FakeAppMailProvider(result: .success(()))
        let app = makeApp(provider: provider)
        app.savedAccounts = [starttls]
        let defaults = MailAccountCredentials(email: starttls.email, appPassword: "pw", host: starttls.host, port: starttls.port)
        _ = await app.testConnection(with: defaults, messageSurface: .shared) { _ in true }
        let saved = try XCTUnwrap(app.savedAccounts.first)
        XCTAssertNil(saved.smtpHost)
        XCTAssertNil(saved.smtpPort)
        XCTAssertNil(saved.smtpSecurity)
        let creds = saved.credentials(appPassword: "pw")
        XCTAssertEqual(creds.smtpPort, 465)
        XCTAssertEqual(creds.smtpSecurity, .implicitTLS)
    }
}
