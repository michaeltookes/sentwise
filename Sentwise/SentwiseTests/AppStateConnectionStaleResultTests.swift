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
}

@MainActor
private final class StaleConnectionResultGate {
    var acceptsResult = true
}
