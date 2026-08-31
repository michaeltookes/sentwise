import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateConnectionStaleResultTests: XCTestCase {

    private let workspaceInvalidCredentials = "[AUTHENTICATIONFAILED] Invalid credentials (Failure)"

    private func makeAppState(provider: MailProvider) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore(),
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    private func workspaceCredentials(email: String = "marcus@acme.com") -> MailAccountCredentials {
        MailAccountCredentials(email: email, appPassword: "abcd efgh ijkl mnop", host: "imap.gmail.com", port: 993)
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
