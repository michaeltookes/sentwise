import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateLocalDataPurgeWatcherTests: XCTestCase {

    private let account = "me@gmail.com"

    private func seededPersistence() -> AppStateMemoryPersistence {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: account, mailbox: .inbox)
        return AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: account,
            savedAccounts: [SavedMailAccount(email: account, host: "imap.gmail.com", port: 993)],
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ), processedMessages: processed)
    }

    func testActiveSavedAccountPurgeFailureRestartsWatcher() {
        let persistence = seededPersistence()
        persistence.purgeError = AppStatePersistenceError.writeDenied
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let app = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        let saved = try? XCTUnwrap(app.savedAccounts.first)
        app.watchStatus = .watching

        if let saved {
            app.removeSavedAccount(saved, purgeLocalData: true)
        }

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertTrue(app.savedAccounts.contains { $0.id == SavedMailAccount.normalizedEmail(account) })
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: account)), "app-pw")
    }
}
