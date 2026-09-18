import SentwiseMail
import XCTest
@testable import Sentwise

/// Regression coverage for PR review feedback around implicit Browse-window
/// account selection when background mailboxes disconnect or are removed.
@MainActor
final class AppStateBrowserDisconnectReviewFeedbackTests: XCTestCase {

    private let focused = "me@gmail.com"
    private let focusedHost = "imap.gmail.com"
    private let background = "side@work.com"
    private let backgroundHost = "imap.work.com"

    private func makeAppState() -> AppState {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: focused): "gmail-pw",
            .mailAppPassword(email: background): "side-pw"
        ])
        let store = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: focused,
            savedAccounts: [
                SavedMailAccount(email: focused, host: focusedHost, port: 993),
                SavedMailAccount(email: background, host: backgroundHost, port: 993)
            ]
        ))
        let app = AppState(
            persistence: store,
            secrets: secrets,
            mailProvider: PagingSearchMailProvider(allMessages: []),
            llm: FakeLLMProvider(result: .success(()))
        )
        app.mailEmail = focused
        app.mailHost = focusedHost
        app.mailPort = 993
        app.mailAppPassword = "gmail-pw"
        app.isAccountConnected = true
        app.backgroundConnectedAccounts = [
            ConnectedMailAccount(email: background, host: backgroundHost, port: 993, appPassword: "side-pw")
        ]
        return app
    }

    private func message(id: UInt32) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: id,
            from: MailAddress(email: "list@news.co"),
            subject: "Weekly",
            date: "",
            messageID: "<\(id)@news.co>"
        )
    }

    private func fallbackAccount() -> ConnectedMailAccount {
        ConnectedMailAccount(
            email: "archive@work.com",
            host: "imap.archive.com",
            port: 993,
            appPassword: "archive-pw"
        )
    }

    private func seedImplicitBackgroundBrowser(
        _ app: AppState,
        fallback: ConnectedMailAccount,
        message: MailMessage
    ) {
        app.backgroundConnectedAccounts.append(fallback)
        app.mailAppPassword = ""
        app.isAccountConnected = false
        app.resetMessagePreviewForAccountChange(clearSkippedMessages: false)
        app.browser.results = [message]
        app.browser.resultQuery = MailboxBrowserQuery(mailbox: .inbox, criteria: app.browser.criteria)
        app.browser.hasSearched = true
        app.browser.toggleSelection(message.id)
        app.bulk.error = "Old cleanup error."
    }

    func testDisconnectingImplicitBrowserAccountResetsBrowserAndBulkState() throws {
        let app = makeAppState()
        let fallback = fallbackAccount()
        seedImplicitBackgroundBrowser(app, fallback: fallback, message: message(id: 43))
        app.bulk.previewAccount = BulkCleanupAccountIdentity(credentials: app.browserCredentials)
        XCTAssertNil(app.browser.accountEmail)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, background)
        let browserGenerationBefore = app.browserGeneration
        let bulkGenerationBefore = app.bulkGeneration
        let account = try XCTUnwrap(app.backgroundConnectedAccounts.first)

        XCTAssertTrue(app.disconnectBackgroundAccount(account))

        XCTAssertNil(app.browser.accountEmail)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, fallback.id)
        XCTAssertTrue(app.browser.results.isEmpty)
        XCTAssertTrue(app.browser.selectedMessageIDs.isEmpty)
        XCTAssertNil(app.browser.resultQuery)
        XCTAssertFalse(app.browser.hasSearched)
        XCTAssertNil(app.bulk.previewAccount)
        XCTAssertNil(app.bulk.error)
        XCTAssertGreaterThan(app.browserGeneration, browserGenerationBefore)
        XCTAssertGreaterThan(app.bulkGeneration, bulkGenerationBefore)
        XCTAssertEqual(app.backgroundConnectedAccounts.map(\.id), [fallback.id])
    }

    func testRemovingImplicitBrowserAccountResetsBeforeRuntimeRemoval() {
        let app = makeAppState()
        let fallback = fallbackAccount()
        seedImplicitBackgroundBrowser(app, fallback: fallback, message: message(id: 44))
        let browserGenerationBefore = app.browserGeneration
        let bulkGenerationBefore = app.bulkGeneration

        app.removeSavedAccount(SavedMailAccount(email: background, host: backgroundHost, port: 993))

        XCTAssertEqual(app.effectiveBrowserAccountEmail, fallback.id)
        XCTAssertTrue(app.browser.results.isEmpty)
        XCTAssertTrue(app.browser.selectedMessageIDs.isEmpty)
        XCTAssertNil(app.browser.resultQuery)
        XCTAssertFalse(app.browser.hasSearched)
        XCTAssertNil(app.bulk.error)
        XCTAssertGreaterThan(app.browserGeneration, browserGenerationBefore)
        XCTAssertGreaterThan(app.bulkGeneration, bulkGenerationBefore)
        XCTAssertEqual(app.backgroundConnectedAccounts.map(\.id), [fallback.id])
        XCTAssertFalse(app.savedAccounts.contains { $0.id == SavedMailAccount.normalizedEmail(background) })
    }
}
