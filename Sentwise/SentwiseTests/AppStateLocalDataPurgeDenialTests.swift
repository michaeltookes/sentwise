import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateLocalDataPurgeDenialTests: XCTestCase {
    func testActiveScopedPurgeClearsRememberedDenialState() throws {
        let account = "me@gmail.com"
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: account,
                mailHost: "imap.gmail.com",
                mailPort: 993,
                savedAccounts: [SavedMailAccount(email: account, host: "imap.gmail.com", port: 993)],
                onboardingCompleted: true
            )
        )
        let app = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(seed: [.mailAppPassword(email: account): "app-pw"]),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier()
        )
        app.lastUsedDenyReason = DenyReason(code: .other, otherText: "private context")
        app.denyReasonPromptSuppressedThisSession = true

        try app.purgeLocalMailArtifacts()

        XCTAssertNil(app.lastUsedDenyReason)
        XCTAssertFalse(app.denyReasonPromptSuppressedThisSession)
    }
}
