import SentwiseMail
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

    func testRemovingActiveAccountClearsSignaturePreferences() async {
        let secrets = InMemorySecretStore()
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence, secrets: secrets)
        let account = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        await connect(appState, email: account.email, host: account.host, password: "gmail-pw")
        appState.signaturePolicy = .custom
        appState.signatureText = "Best,\nGmail Me"

        appState.removeSavedAccount(account)

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertEqual(appState.signaturePolicy, .none)
        XCTAssertEqual(appState.signatureText, "")
        XCTAssertEqual(persistence.loadSettings().signaturePolicy, SignaturePolicy.none.rawValue)
        XCTAssertEqual(persistence.loadSettings().signatureText, "")
    }

    func testRestoredSkippedMessagesKeepSweepRecoveryDespiteProcessedSource() {
        let message = skippedSourceMessage()
        let regularSkip = SkippedMessage(message: message, mailbox: .inbox, account: "me@gmail.com", reason: .noReplySender)
        let sweptSkip = SkippedMessage(
            message: MailMessage(
                id: 2,
                uidValidity: 7,
                from: MailAddress(email: "auto-confirm@amazon.com"),
                subject: "Order",
                date: "",
                messageID: "<2@example.com>"
            ),
            mailbox: .inbox,
            account: "me@gmail.com",
            reason: .automatedNotification,
            preservesRecoveryWhenProcessed: true
        )
        var processed = ProcessedMessages()
        processed.insert(message, account: "me@gmail.com", mailbox: .inbox)
        processed.insert(sweptSkip.message, account: "me@gmail.com", mailbox: .inbox)
        let persistence = AppStateMemoryPersistence(skippedMessages: [regularSkip, sweptSkip])

        let restored = AppState.restoredSkippedMessages(
            persistence: persistence,
            processedMessages: processed,
            accountEmail: "me@gmail.com",
            limit: 10
        )

        XCTAssertEqual(restored, [sweptSkip])
        XCTAssertEqual(persistence.skippedMessages, [sweptSkip])
    }

    func testAccountChangeReloadsVisibleSkippedMessagesWithoutClearingPersistence() {
        let primary = SkippedMessage(
            message: skippedSourceMessage(id: 1, from: "no-reply@example.com"),
            mailbox: .inbox,
            account: "me@gmail.com",
            reason: .noReplySender,
            preservesRecoveryWhenProcessed: true
        )
        let secondary = SkippedMessage(
            message: skippedSourceMessage(id: 2, from: "auto-confirm@amazon.com"),
            mailbox: .inbox,
            account: "other@gmail.com",
            reason: .automatedNotification,
            preservesRecoveryWhenProcessed: true
        )
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com"
            ),
            skippedMessages: [primary, secondary]
        )
        let appState = makeAppState(persistence: persistence)
        XCTAssertEqual(appState.skippedMessages, [primary])

        appState.mailEmail = "other@gmail.com"
        appState.resetMessagePreviewForAccountChange()

        XCTAssertEqual(appState.skippedMessages, [secondary])
        XCTAssertEqual(persistence.skippedMessages, [primary, secondary])

        appState.mailEmail = ""
        appState.resetMessagePreviewForAccountChange()

        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertEqual(persistence.skippedMessages, [primary, secondary])
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

    private func skippedSourceMessage(
        id: UInt32 = 1,
        from: String = "no-reply@example.com"
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 7,
            from: MailAddress(email: from),
            subject: "Receipt",
            date: "",
            messageID: "<\(id)@example.com>"
        )
    }
}
