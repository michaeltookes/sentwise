import SentwiseMail
import XCTest
@testable import Sentwise

/// The Browse Mailbox account picker (item 103): browse/search/pagination and
/// bulk cleanup follow the picked mailbox's credentials, switching accounts
/// resets browser state without touching the focused account, and the picker's
/// visibility and confirmation copy reflect the multi-account world.
@MainActor
final class AppStateBrowserAccountTests: XCTestCase {

    private let focused = "me@gmail.com"
    private let focusedHost = "imap.gmail.com"
    private let background = "side@work.com"
    private let backgroundHost = "imap.work.com"

    private func makeAppState(provider: MailProvider) -> AppState {
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
            mailProvider: provider,
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

    // MARK: - Credential selection

    func testBrowserCredentialsDefaultsToFocusedAccount() {
        let app = makeAppState(provider: PagingSearchMailProvider(allMessages: []))
        XCTAssertNil(app.browserAccountEmail)
        XCTAssertEqual(app.browserCredentials.email, focused)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, focused)
    }

    func testSelectBrowserAccountSwapsCredentialsToPickedAccount() {
        let app = makeAppState(provider: PagingSearchMailProvider(allMessages: []))
        app.selectBrowserAccount(background)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, background)
        XCTAssertEqual(app.browserCredentials.email, background)
        XCTAssertEqual(app.browserCredentials.host, backgroundHost)
        XCTAssertEqual(app.browserCredentials.appPassword, "side-pw")
        // The global focused account is untouched.
        XCTAssertEqual(app.mailEmail, focused)
        XCTAssertEqual(app.mailCredentials.email, focused)
    }

    func testSearchUsesPickedAccountCredentials() async {
        let provider = PagingSearchMailProvider(allMessages: [])
        let app = makeAppState(provider: provider)

        await app.runMailboxSearch()
        XCTAssertEqual(provider.lastCredentials?.email, focused)

        app.selectBrowserAccount(background)
        await app.runMailboxSearch()
        XCTAssertEqual(provider.lastCredentials?.email, background)
        XCTAssertEqual(provider.lastCredentials?.host, backgroundHost)
    }

    func testSelectBrowserAccountIgnoresUnconnectedEmail() {
        let app = makeAppState(provider: PagingSearchMailProvider(allMessages: []))
        app.selectBrowserAccount("stranger@nowhere.com")
        XCTAssertNil(app.browserAccountEmail)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, focused)
    }

    func testEffectiveBrowserAccountFallsBackWhenPickedDisconnects() {
        let app = makeAppState(provider: PagingSearchMailProvider(allMessages: []))
        app.selectBrowserAccount(background)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, background)
        // The picked mailbox disconnects: the browser falls back to focused
        // rather than pointing at a mailbox with no live credentials.
        app.backgroundConnectedAccounts = []
        XCTAssertEqual(app.effectiveBrowserAccountEmail, focused)
        XCTAssertEqual(app.browserCredentials.email, focused)
    }

    // MARK: - State reset on switch

    func testSwitchingAccountResetsBrowserStateAndGeneration() async {
        let provider = PagingSearchMailProvider(allMessages: [])
        let app = makeAppState(provider: provider)
        await app.runMailboxSearch()
        app.browser.keyword = "invoice"
        app.browser.selectAllLoaded()
        let generationBefore = app.browserGeneration
        let bulkGenerationBefore = app.bulkGeneration

        app.selectBrowserAccount(background)

        // Inputs, results, and selection are wiped so nothing mixes across
        // accounts, and both generation counters advanced to invalidate any
        // in-flight page/cleanup. (Full-state equality is avoided because
        // MailboxBrowserState() seeds its date filters with Date().)
        XCTAssertEqual(app.browser.keyword, "")
        XCTAssertTrue(app.browser.results.isEmpty)
        XCTAssertTrue(app.browser.selectedMessageIDs.isEmpty)
        XCTAssertNil(app.browser.resultQuery)
        XCTAssertFalse(app.browser.hasSearched)
        XCTAssertGreaterThan(app.browserGeneration, generationBefore)
        XCTAssertGreaterThan(app.bulkGeneration, bulkGenerationBefore)
    }

    func testFocusedAccountChangeClearsBrowserAccountOverride() {
        let app = makeAppState(provider: PagingSearchMailProvider(allMessages: []))
        app.selectBrowserAccount(background)
        XCTAssertEqual(app.browserAccountEmail, background)
        // Switching the focused account (or disconnecting) resets the browser to
        // the new focused account.
        app.resetMessagePreviewForAccountChange()
        XCTAssertNil(app.browserAccountEmail)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, focused)
    }

    // MARK: - Picker visibility

    func testPickerHiddenForSingleConnectedAccount() {
        let app = makeAppState(provider: PagingSearchMailProvider(allMessages: []))
        app.backgroundConnectedAccounts = []
        XCTAssertFalse(app.showsBrowserAccountPicker)
        XCTAssertEqual(app.browsableAccountEmails, [focused])
    }

    func testPickerShownForMultipleConnectedAccounts() {
        let app = makeAppState(provider: PagingSearchMailProvider(allMessages: []))
        XCTAssertTrue(app.showsBrowserAccountPicker)
        XCTAssertEqual(app.browsableAccountEmails, [focused, background])
    }

    // MARK: - Bulk cleanup scoping (item 103)

    func testBulkCleanupPreviewUsesPickedAccountCredentials() async {
        let sample = MailMessage(
            id: 42, uidValidity: 1,
            from: MailAddress(name: nil, email: "list@news.co"),
            subject: "Weekly", date: "", messageID: "<42@news.co>"
        )
        let provider = BulkCleanupMailProvider(previewResult: .success(
            MailBulkPreview(
                matchCount: 1, sample: [sample], isPartial: false,
                selection: MailBulkSelection(uidValidity: 1, uids: [42])
            )
        ))
        let app = makeAppState(provider: provider)
        app.selectBrowserAccount(background)
        app.bulk.action = .moveToTrash

        await app.previewBulkCleanup()

        XCTAssertEqual(provider.lastPreviewCredentials?.email, background)
        XCTAssertEqual(provider.lastPreviewCredentials?.host, backgroundHost)
        XCTAssertEqual(app.bulk.previewAccount, BulkCleanupAccountIdentity(credentials: app.browserCredentials))
    }

    // MARK: - Confirmation copy names the account

    func testBulkConfirmationNamesPickedAccount() {
        XCTAssertEqual(
            AppState.bulkConfirmationMessage(
                for: .moveToTrash, matchCount: 3, isPartial: false, account: background
            ),
            "Move all 3 messages in side@work.com matching this filter to Trash?"
                + " This runs in repeated passes until every match is gone,"
                + " so it may move more than the 3 visible now. You can recover them from Trash."
        )
        // Single account (nil): unqualified copy, unchanged from before.
        XCTAssertEqual(
            AppState.bulkSelectionConfirmationMessage(for: .markRead, count: 2, account: nil),
            "Mark 2 checked messages as read?"
        )
        XCTAssertEqual(
            AppState.bulkSelectionConfirmationMessage(for: .archive, count: 1, account: background),
            "Archive 1 checked message in side@work.com? You can find them in the Archive folder."
        )
    }

    func testBulkAccountClauseOmittedForBlankOrNil() {
        XCTAssertEqual(AppState.bulkAccountClause(nil), "")
        XCTAssertEqual(AppState.bulkAccountClause("   "), "")
        XCTAssertEqual(AppState.bulkAccountClause("side@work.com"), " in side@work.com")
    }
}
