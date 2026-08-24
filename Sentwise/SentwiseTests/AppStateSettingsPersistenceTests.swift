import XCTest
@testable import Sentwise

@MainActor
final class AppStateSettingsPersistenceTests: XCTestCase {

    func testSignatureAutosavePersistsCommittedPublishedValues() async throws {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )

        appState.signaturePolicy = .custom
        appState.signatureText = "Best,\nGmail Me"
        try await Task.sleep(nanoseconds: 650_000_000)

        let settings = persistence.loadSettings()
        XCTAssertEqual(settings.signaturePolicy, SignaturePolicy.custom.rawValue)
        XCTAssertEqual(settings.signatureText, "Best,\nGmail Me")
    }

    func testReconnectingSameAccountRetainsSignaturePreferences() async {
        let secrets = InMemorySecretStore()
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence, secrets: secrets)
        await connect(appState, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        appState.signaturePolicy = .custom
        appState.signatureText = "Best,\nGmail Me"

        appState.disconnectMail()
        await connect(appState, email: "me@gmail.com", host: "imap.gmail.com", password: "new-gmail-pw")

        let active = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        XCTAssertTrue(appState.isActiveAccount(active))
        XCTAssertEqual(appState.signaturePolicy, .custom)
        XCTAssertEqual(appState.signatureText, "Best,\nGmail Me")
        XCTAssertEqual(persistence.loadSettings().signaturePolicy, SignaturePolicy.custom.rawValue)
        XCTAssertEqual(persistence.loadSettings().signatureText, "Best,\nGmail Me")
    }

    private func makeAppState(
        persistence: AppStateMemoryPersistence,
        secrets: SecretStore = InMemorySecretStore()
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    private func connect(_ appState: AppState, email: String, host: String, password: String) async {
        appState.mailEmail = email
        appState.mailHost = host
        appState.mailPort = 993
        appState.mailAppPassword = password
        await appState.testConnection()
    }
}
