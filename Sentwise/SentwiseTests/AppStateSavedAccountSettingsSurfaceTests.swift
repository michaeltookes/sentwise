import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateSavedAccountSettingsSurfaceTests: XCTestCase {

    func testSettingsSwitchSuccessIgnoresSharedConnectionErrorFallback() async {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let att = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: att.email,
            mailHost: att.host,
            mailPort: att.port,
            savedAccounts: [gmail, att]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail.email): "gmail-pw",
            .mailAppPassword(email: att.email): "att-pw"
        ])
        let persistence = AppStateMemoryPersistence(settings: settings)
        let app = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        app.isAccountConnected = true
        app.connectionError = "startup keychain warning"

        await app.switchToSavedAccount(gmail, messageSurface: .settings)

        XCTAssertEqual(app.connectionError, "startup keychain warning")
        XCTAssertTrue(app.isActiveAccount(gmail))
        XCTAssertEqual(app.mailEmail, gmail.email)
        XCTAssertEqual(persistence.loadSettings().mailEmail, gmail.email)
    }
}
