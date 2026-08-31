import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class SavedAccountGuidanceRemovalTests: XCTestCase {

    func testRemovingDisconnectedCurrentAccountClearsWorkspaceGuidance() {
        let account = SavedMailAccount(
            email: "marcus@company.example",
            host: "imap.gmail.com",
            port: 993
        )
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: account.email,
            mailHost: account.host,
            mailPort: account.port,
            savedAccounts: [account]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account.email): "company-pw"
        ])
        let appState = AppState(
            persistence: AppStateMemoryPersistence(settings: settings),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        appState.isAccountConnected = false
        appState.workspaceAuthFailure = .appPasswordRejectedWorkspace
        appState.workspaceAuthIsCustomDomain = true
        XCTAssertNotNil(appState.workspaceAuthGuidance)

        appState.removeSavedAccount(account)

        XCTAssertNil(appState.connectionError)
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertEqual(appState.mailEmail, "")
        XCTAssertEqual(appState.workspaceAuthFailure, .none)
        XCTAssertFalse(appState.workspaceAuthIsCustomDomain)
        XCTAssertNil(appState.workspaceAuthGuidance)
        XCTAssertEqual(appState.savedAccounts, [])
    }
}
