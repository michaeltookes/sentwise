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

    private func makeDraftingAppState(provider: MailProvider) -> (AppState, FakeLLMProvider) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: focused): "gmail-pw",
            .mailAppPassword(email: background): "side-pw",
            .llmAPIKey(provider: "anthropic"): "sk-test"
        ])
        let store = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: focused,
            savedAccounts: [
                SavedMailAccount(email: focused, host: focusedHost, port: 993),
                SavedMailAccount(email: background, host: backgroundHost, port: 993)
            ],
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let llm = FakeLLMProvider(
            result: .success(()),
            completion: .success(LLMResponse(text: "Reply from selected account."))
        )
        let app = AppState(
            persistence: store,
            secrets: secrets,
            mailProvider: provider,
            llm: llm
        )
        app.mailEmail = focused
        app.mailHost = focusedHost
        app.mailPort = 993
        app.mailAppPassword = "gmail-pw"
        app.isAccountConnected = true
        app.backgroundConnectedAccounts = [
            ConnectedMailAccount(email: background, host: backgroundHost, port: 993, appPassword: "side-pw")
        ]
        return (app, llm)
    }

    // MARK: - Credential selection

    func testBrowserCredentialsDefaultsToFocusedAccount() {
        let app = makeAppState(provider: PagingSearchMailProvider(allMessages: []))
        XCTAssertNil(app.browser.accountEmail)
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

    func testPreviewBodyUsesPickedAccountCredentials() async {
        let provider = PagingSearchMailProvider(allMessages: [])
        let app = makeAppState(provider: provider)
        app.selectBrowserAccount(background)
        let message = MailMessage(
            id: 77,
            uidValidity: 12,
            from: MailAddress(email: "alice@example.com"),
            subject: "Background body",
            date: ""
        )

        let preview = await app.previewBody(
            for: message,
            mailbox: .inbox,
            credentials: app.browserCredentials
        )

        XCTAssertEqual(preview?.id, 77)
        XCTAssertEqual(provider.lastBodyUID, 77)
        XCTAssertEqual(provider.lastBodyCredentials?.email, background)
        XCTAssertEqual(provider.lastBodyCredentials?.host, backgroundHost)
    }

    func testGenerateDraftUsesPickedAccountCredentials() async {
        let provider = PagingSearchMailProvider(allMessages: [])
        let (app, _) = makeDraftingAppState(provider: provider)
        app.selectBrowserAccount(background)
        let message = MailMessage(
            id: 88,
            uidValidity: 13,
            from: MailAddress(name: "Alice", email: "alice@example.com"),
            subject: "Background draft",
            date: ""
        )

        let draft = await app.generateDraft(
            for: message,
            mailbox: .inbox,
            credentials: app.browserCredentials
        )

        XCTAssertEqual(draft?.id, 88)
        XCTAssertEqual(draft?.body, "Reply from selected account.")
        XCTAssertEqual(draft?.sourceAccountEmail, background)
        XCTAssertEqual(draft?.sourceMailHost, backgroundHost)
        XCTAssertEqual(provider.lastBodyUID, 88)
        XCTAssertEqual(provider.lastBodyCredentials?.email, background)
        XCTAssertEqual(provider.lastBodyCredentials?.host, backgroundHost)
    }

    func testDraftAnywayUsesSkippedMessageAccountCredentials() async {
        let provider = PagingSearchMailProvider(allMessages: [])
        let (app, _) = makeDraftingAppState(provider: provider)
        let message = MailMessage(
            id: 99,
            uidValidity: 14,
            from: MailAddress(name: "Alice", email: "alice@example.com"),
            subject: "Background skip",
            date: "",
            messageID: "<99@example.com>"
        )
        let entry = SkippedMessage(
            message: message,
            mailbox: .inbox,
            account: background,
            reason: .bulkOrListMail
        )

        let didCreateDraft = await app.forceDraftSkippedMessage(entry)

        XCTAssertTrue(didCreateDraft)
        XCTAssertEqual(provider.lastBodyUID, 99)
        XCTAssertEqual(provider.lastBodyCredentials?.email, background)
        XCTAssertEqual(provider.lastBodyCredentials?.host, backgroundHost)
        XCTAssertTrue(app.pendingDrafts.contains { draft in
            draft.id == 99 && draft.sourceAccountEmail == background
        })
    }

    func testSelectBrowserAccountIgnoresUnconnectedEmail() {
        let app = makeAppState(provider: PagingSearchMailProvider(allMessages: []))
        app.selectBrowserAccount("stranger@nowhere.com")
        XCTAssertNil(app.browser.accountEmail)
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

    func testBrowserFallsBackToBackgroundWhenFocusedAccountDisconnects() {
        let app = makeAppState(provider: PagingSearchMailProvider(allMessages: []))

        app.mailAppPassword = ""
        app.isAccountConnected = false
        app.resetMessagePreviewForAccountChange(clearSkippedMessages: false)

        XCTAssertFalse(app.showsBrowserAccountPicker)
        XCTAssertEqual(app.browsableAccountEmails, [background])
        XCTAssertEqual(app.effectiveBrowserAccountEmail, background)
        XCTAssertEqual(app.browserCredentials.email, background)
        XCTAssertEqual(app.browserCredentials.host, backgroundHost)
        XCTAssertEqual(app.browserCredentials.appPassword, "side-pw")
    }

    func testBrowserDraftEligibilityUsesEffectiveBrowserCredentials() {
        let provider = PagingSearchMailProvider(allMessages: [])
        let (app, _) = makeDraftingAppState(provider: provider)

        XCTAssertTrue(app.canGenerateDraft)
        XCTAssertTrue(app.canGenerateBrowserDraft)

        app.mailAppPassword = ""
        app.isAccountConnected = false
        app.resetMessagePreviewForAccountChange(clearSkippedMessages: false)

        XCTAssertFalse(app.canGenerateDraft)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, background)
        XCTAssertEqual(app.browserCredentials.email, background)
        XCTAssertTrue(app.canGenerateBrowserDraft)
    }

    func testDisconnectingSelectedBrowserAccountResetsBrowserAndBulkState() async throws {
        let message = MailMessage(
            id: 42,
            uidValidity: 1,
            from: MailAddress(email: "list@news.co"),
            subject: "Weekly",
            date: "",
            messageID: "<42@news.co>"
        )
        let provider = PagingSearchMailProvider(allMessages: [message])
        let app = makeAppState(provider: provider)
        app.selectBrowserAccount(background)
        await app.runMailboxSearch()
        app.browser.selectAllLoaded()
        app.bulk.error = "Old cleanup error."
        app.bulk.previewAccount = BulkCleanupAccountIdentity(credentials: app.browserCredentials)
        let browserGenerationBefore = app.browserGeneration
        let bulkGenerationBefore = app.bulkGeneration
        let account = try XCTUnwrap(app.backgroundConnectedAccounts.first)

        XCTAssertTrue(app.disconnectBackgroundAccount(account))

        XCTAssertNil(app.browser.accountEmail)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, focused)
        XCTAssertTrue(app.browser.results.isEmpty)
        XCTAssertTrue(app.browser.selectedMessageIDs.isEmpty)
        XCTAssertNil(app.browser.resultQuery)
        XCTAssertFalse(app.browser.hasSearched)
        XCTAssertNil(app.bulk.previewAccount)
        XCTAssertNil(app.bulk.error)
        XCTAssertGreaterThan(app.browserGeneration, browserGenerationBefore)
        XCTAssertGreaterThan(app.bulkGeneration, bulkGenerationBefore)
        XCTAssertTrue(app.backgroundConnectedAccounts.isEmpty)
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
        XCTAssertEqual(app.browser.accountEmail, background)
        // Switching the focused account (or disconnecting) resets the browser to
        // the new focused account.
        app.resetMessagePreviewForAccountChange()
        XCTAssertNil(app.browser.accountEmail)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, focused)
    }

    func testSameAccountConnectionTestPreservesBrowserSelection() async {
        let message = MailMessage(
            id: 42,
            uidValidity: 1,
            from: MailAddress(email: "alice@example.com"),
            subject: "Invoice",
            date: "",
            messageID: "<42@example.com>"
        )
        let provider = PagingSearchMailProvider(allMessages: [message])
        let app = makeAppState(provider: provider)
        app.selectBrowserAccount(background)
        app.browser.keyword = "invoice"
        await app.runMailboxSearch()
        app.browser.selectAllLoaded()
        app.recentMessages = [
            MailMessage(id: 1, from: MailAddress(email: "old@example.com"), subject: "Old", date: "")
        ]

        await app.testConnection(with: MailAccountCredentials(
            email: focused,
            appPassword: "gmail-pw",
            host: focusedHost,
            port: 993
        ))

        XCTAssertEqual(app.browser.accountEmail, background)
        XCTAssertEqual(app.effectiveBrowserAccountEmail, background)
        XCTAssertEqual(app.browser.keyword, "invoice")
        XCTAssertEqual(app.browser.results.map(\.id), [42])
        XCTAssertTrue(app.browser.selectedMessageIDs.contains(42))
        XCTAssertTrue(app.recentMessages.isEmpty)
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
