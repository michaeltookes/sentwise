import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStatePurgeAccountSwitchTests: XCTestCase {
    func testEraseAllInvalidatesPendingSavedAccountSwitch() async {
        let active = "active@gmail.com"
        let target = "target@gmail.com"
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: active,
                mailHost: "imap.gmail.com",
                mailPort: 993,
                savedAccounts: [
                    SavedMailAccount(email: active, host: "imap.gmail.com", port: 993),
                    SavedMailAccount(email: target, host: "imap.gmail.com", port: 993)
                ],
                onboardingCompleted: true
            )
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: active): "active-pw",
            .mailAppPassword(email: target): "target-pw"
        ])
        let mailProvider = SuspendedAppMailProvider()
        let app = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: mailProvider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier()
        )
        let targetAccount = try? XCTUnwrap(app.savedAccounts.first { $0.email == target })

        let switchTask = Task {
            if let targetAccount {
                await app.switchToSavedAccount(targetAccount)
            }
        }
        await fulfillment(of: [mailProvider.didStartVerification], timeout: 1)

        let result = await app.eraseAllLocalData()
        mailProvider.complete(with: .success(()))
        await switchTask.value

        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertTrue(app.mailEmail.isEmpty)
        XCTAssertTrue(app.savedAccounts.isEmpty)
        XCTAssertEqual(persistence.loadSettings(), Settings.default.validated())
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: target))) ?? nil)
    }
}
