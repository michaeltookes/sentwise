import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateConnectionStaleResultTests: XCTestCase {

    private let workspaceInvalidCredentials = "[AUTHENTICATIONFAILED] Invalid credentials (Failure)"

    private func makeAppState(
        provider: MailProvider,
        secrets: SecretStore = InMemorySecretStore(),
        persistence: AppStateMemoryPersistence = AppStateMemoryPersistence()
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    private func workspaceCredentials(email: String = "marcus@acme.com") -> MailAccountCredentials {
        MailAccountCredentials(email: email, appPassword: "abcd efgh ijkl mnop", host: "imap.gmail.com", port: 993)
    }

    func testExplicitConnectionPersistsVerifiedCredentialSnapshot() async {
        let secrets = InMemorySecretStore()
        let provider = SuspendedAppMailProvider()
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(provider: provider, secrets: secrets, persistence: persistence)
        let credentials = MailAccountCredentials(
            email: "me@gmail.com",
            appPassword: "verified-pw",
            host: "imap.gmail.com",
            port: 993
        )

        let connectionTask = Task { await appState.testConnection(with: credentials) }
        await fulfillment(of: [provider.didStartVerification], timeout: 1)

        appState.mailEmail = "other@example.com"
        appState.mailAppPassword = "other-pw"
        appState.mailHost = "imap.example.com"
        appState.mailPort = 1993
        provider.complete(with: .success(()))
        let didConnect = await connectionTask.value

        let settings = persistence.loadSettings()
        XCTAssertTrue(didConnect)
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(appState.mailEmail, "me@gmail.com")
        XCTAssertEqual(appState.mailAppPassword, "verified-pw")
        XCTAssertEqual(appState.mailHost, "imap.gmail.com")
        XCTAssertEqual(appState.mailPort, 993)
        XCTAssertEqual(settings.mailEmail, "me@gmail.com")
        XCTAssertEqual(settings.mailHost, "imap.gmail.com")
        XCTAssertEqual(settings.mailPort, 993)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")), "verified-pw")
        XCTAssertEqual(provider.lastCredentials?.email, "me@gmail.com")
        XCTAssertEqual(provider.lastCredentials?.appPassword, "verified-pw")
    }

    func testEditedMainCredentialsIgnoreStaleWorkspaceFailure() async {
        let provider = SuspendedAppMailProvider()
        let appState = makeAppState(provider: provider)
        appState.updateMailEmailFromUser("marcus@acme.com")
        appState.updateMailHostFromUser("imap.gmail.com")
        appState.updateMailAppPasswordFromUser("abcd efgh ijkl mnop")

        let connection = Task { await appState.testConnection() }
        await fulfillment(of: [provider.didStartVerification], timeout: 1)

        appState.updateMailEmailFromUser("me@gmail.com")
        provider.complete(with: .failure(MailError.authenticationFailed(workspaceInvalidCredentials)))
        let didConnect = await connection.value

        XCTAssertFalse(didConnect)
        XCTAssertNil(appState.connectionError)
        XCTAssertEqual(appState.workspaceAuthFailure, .none)
        XCTAssertNil(appState.workspaceAuthGuidance)
        XCTAssertFalse(appState.activityEvents.contains { $0.kind == .workspaceAuthGuidance })
    }

    func testEditedMainCredentialsIgnoreStaleSuccess() async {
        let provider = SuspendedAppMailProvider()
        let appState = makeAppState(provider: provider)
        appState.updateMailEmailFromUser("marcus@acme.com")
        appState.updateMailHostFromUser("imap.gmail.com")
        appState.updateMailAppPasswordFromUser("abcd efgh ijkl mnop")

        let connection = Task { await appState.testConnection() }
        await fulfillment(of: [provider.didStartVerification], timeout: 1)

        appState.updateMailEmailFromUser("me@gmail.com")
        provider.complete(with: .success(()))
        let didConnect = await connection.value

        XCTAssertFalse(didConnect)
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertEqual(appState.mailEmail, "me@gmail.com")
        XCTAssertTrue(appState.savedAccounts.isEmpty)
    }

    func testAbandonedExplicitCredentialsIgnoreStaleWorkspaceFailure() async {
        let provider = SuspendedAppMailProvider()
        let appState = makeAppState(provider: provider)
        let gate = StaleConnectionResultGate()
        let connection = Task {
            await appState.testConnection(with: workspaceCredentials()) { _ in gate.acceptsResult }
        }
        await fulfillment(of: [provider.didStartVerification], timeout: 1)

        gate.acceptsResult = false
        provider.complete(with: .failure(MailError.authenticationFailed(workspaceInvalidCredentials)))
        let didConnect = await connection.value

        XCTAssertFalse(didConnect)
        XCTAssertNil(appState.connectionError)
        XCTAssertEqual(appState.workspaceAuthFailure, .none)
        XCTAssertNil(appState.workspaceAuthGuidance)
        XCTAssertFalse(appState.activityEvents.contains { $0.kind == .workspaceAuthGuidance })
    }

    func testAbandonedExplicitCredentialsIgnoreStaleSuccess() async {
        let provider = SuspendedAppMailProvider()
        let appState = makeAppState(provider: provider)
        let gate = StaleConnectionResultGate()
        let connection = Task {
            await appState.testConnection(with: workspaceCredentials()) { _ in gate.acceptsResult }
        }
        await fulfillment(of: [provider.didStartVerification], timeout: 1)

        gate.acceptsResult = false
        provider.complete(with: .success(()))
        let didConnect = await connection.value

        XCTAssertFalse(didConnect)
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertEqual(appState.mailEmail, "")
        XCTAssertTrue(appState.savedAccounts.isEmpty)
    }

    func testSettingsResetIgnoresExplicitConnectionFailure() async {
        let provider = SuspendedAppMailProvider()
        let appState = makeAppState(provider: provider)
        let connection = Task {
            await appState.testConnection(with: workspaceCredentials(), messageSurface: .settings)
        }
        await fulfillment(of: [provider.didStartVerification], timeout: 1)

        appState.resetTransientSettingsMessages()
        provider.complete(with: .failure(MailError.authenticationFailed(workspaceInvalidCredentials)))
        let didConnect = await connection.value

        XCTAssertFalse(didConnect)
        XCTAssertNil(appState.connectionError)
        XCTAssertEqual(appState.workspaceAuthFailure, .none)
        XCTAssertNil(appState.workspaceAuthGuidance)
        XCTAssertFalse(appState.activityEvents.contains { $0.kind == .workspaceAuthGuidance })
    }

    func testSettingsResetIgnoresExplicitConnectionSuccess() async {
        let provider = SuspendedAppMailProvider()
        let appState = makeAppState(provider: provider)
        let connection = Task {
            await appState.testConnection(with: workspaceCredentials(), messageSurface: .settings)
        }
        await fulfillment(of: [provider.didStartVerification], timeout: 1)

        appState.resetTransientSettingsMessages()
        provider.complete(with: .success(()))
        let didConnect = await connection.value

        XCTAssertFalse(didConnect)
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertEqual(appState.mailEmail, "")
        XCTAssertTrue(appState.savedAccounts.isEmpty)
    }

    func testSettingsConnectionFailureUsesSettingsErrorBucket() async {
        let provider = FakeAppMailProvider(result: .failure(.connectionFailed("offline")))
        let appState = makeAppState(provider: provider)
        appState.connectionError = "setup assistant error"

        let didConnect = await appState.testConnection(
            with: workspaceCredentials(email: "marcus@example.com"),
            messageSurface: .settings
        )

        XCTAssertFalse(didConnect)
        XCTAssertEqual(appState.connectionError, "setup assistant error")
        XCTAssertTrue(appState.connectionError(for: .settings)?.contains("offline") ?? false)
    }

    func testSettingsConnectionSuccessClearsSharedConnectionFallback() async {
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider)
        appState.connectionError = "setup assistant error"

        let didConnect = await appState.testConnection(
            with: workspaceCredentials(email: "marcus@example.com"),
            messageSurface: .settings
        )

        XCTAssertTrue(didConnect)
        XCTAssertNil(appState.connectionError)
        XCTAssertNil(appState.connectionError(for: .settings))
    }

    func testSettingsWorkspaceAuthFailureUsesSettingsGuidanceBucket() async {
        let provider = FakeAppMailProvider(result: .failure(.authenticationFailed(workspaceInvalidCredentials)))
        let appState = makeAppState(provider: provider)
        appState.workspaceAuthFailure = .webLoginRequired
        appState.workspaceAuthFailureAccountID = "setup"
        appState.workspaceAuthIsCustomDomain = false

        let didConnect = await appState.testConnection(
            with: workspaceCredentials(email: "marcus@example.com"),
            messageSurface: .settings
        )

        XCTAssertFalse(didConnect)
        XCTAssertEqual(appState.workspaceAuthFailure, .webLoginRequired)
        XCTAssertEqual(appState.workspaceAuthFailureAccountID, "setup")
        XCTAssertFalse(appState.workspaceAuthIsCustomDomain)
        XCTAssertNotNil(appState.workspaceAuthGuidance)
        XCTAssertNotNil(appState.workspaceAuthGuidance(for: .settings))
        XCTAssertEqual(appState.settingsTransientMessages.workspaceAuthFailure, .appPasswordRejectedWorkspace)
        XCTAssertEqual(appState.settingsTransientMessages.workspaceAuthFailureAccountID, "marcus@example.com")
        XCTAssertTrue(appState.settingsTransientMessages.workspaceAuthIsCustomDomain)
    }
}

@MainActor
private final class StaleConnectionResultGate {
    var acceptsResult = true
}
