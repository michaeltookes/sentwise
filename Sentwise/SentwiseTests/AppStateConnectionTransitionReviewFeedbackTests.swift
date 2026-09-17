import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateConnectTransitionFeedbackTests: XCTestCase {

    func testReconnectFromEmptyFocusedSlotRemovesDuplicateBackgroundRuntime() async {
        let account = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "",
            savedAccounts: [account],
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account.email): "gmail-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let app = AppState(
            persistence: AppStateMemoryPersistence(settings: settings),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        app.backgroundConnectedAccounts = [
            ConnectedMailAccount(
                email: account.email,
                host: account.host,
                port: account.port,
                appPassword: "gmail-pw"
            )
        ]

        await app.testConnection(with: MailAccountCredentials(
            email: account.email,
            appPassword: "gmail-pw",
            host: account.host,
            port: account.port
        ))

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, account.email)
        XCTAssertTrue(app.backgroundConnectedAccounts.isEmpty)
        XCTAssertEqual(app.connectedAccountCount, 1)
    }
}
