import SentwiseMail
import XCTest
@testable import Sentwise

/// Concurrent per-account watchers (item 99): a background connected account polls
/// with its own credentials, drafts in its own account attribution, and has its
/// own watch status independent of the focused account.
@MainActor
final class AppStateConcurrentWatcherTests: XCTestCase {

    private let focused = "me@gmail.com"
    private let background = "bob@side.com"

    private func message(id: UInt32, from: String = "alice@x.com") -> MailMessage {
        MailMessage(
            id: id,
            from: MailAddress(name: "Alice", email: from),
            subject: "Subject \(id)",
            date: "",
            messageID: "<\(id)@x.com>"
        )
    }

    /// A processed store with a seeded baseline for both accounts, so a poll drafts
    /// the fetched message immediately instead of seeding a fresh baseline.
    private func baselinedProcessed() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: focused, mailbox: .inbox)
        processed.insertBaseline(account: background, mailbox: .inbox)
        return processed
    }

    private func makeAppState(
        fetch: Result<[MailMessage], MailError>
    ) -> (AppState, ConnectedMailAccount) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: focused): "gmail-pw",
            .mailAppPassword(email: background): "side-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: focused,
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6"
            ),
            processedMessages: baselinedProcessed()
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: fetch,
            bodyResult: .success(Data("Please advise.".utf8))
        )
        let llm = FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "On it.")))
        let app = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        app.mailAppPassword = "gmail-pw"
        app.retryRunner = .immediate
        let account = ConnectedMailAccount(
            email: background, host: "imap.side.com", port: 993, appPassword: "side-pw"
        )
        app.backgroundConnectedAccounts = [account]
        return (app, account)
    }

    func testBackgroundAccountPollDraftsUnderItsOwnAttribution() async {
        let (app, account) = makeAppState(fetch: .success([message(id: 7)]))
        account.watchStatus = .watching

        await app.pollInbox(account: account)

        XCTAssertEqual(app.pendingDrafts.count, 1)
        XCTAssertEqual(app.pendingDrafts.first?.sourceAccountEmail, background)
    }

    func testBackgroundPollSkipsWhenAccountNotWatching() async {
        let (app, account) = makeAppState(fetch: .success([message(id: 7)]))
        account.watchStatus = .idle

        await app.pollInbox(account: account)

        XCTAssertTrue(app.pendingDrafts.isEmpty)
    }

    func testFocusedAndBackgroundAccountsDraftIndependently() async {
        // Both watchers fetch the same message id from their own mailboxes; each
        // enqueues a draft attributed to its own account.
        let (app, account) = makeAppState(fetch: .success([message(id: 7)]))
        app.watchStatus = .watching
        account.watchStatus = .watching

        await app.pollInbox(account: nil)          // focused account
        await app.pollInbox(account: account)      // background account

        let attributions = Set(app.pendingDrafts.compactMap(\.sourceAccountEmail))
        XCTAssertEqual(app.pendingDrafts.count, 2)
        XCTAssertEqual(attributions, [focused, background])
    }

    func testBackgroundWatcherLifecycleTracksPerAccountStatus() {
        let (app, account) = makeAppState(fetch: .success([]))

        app.startWatching(account: account)
        XCTAssertEqual(account.watchStatus, .watching)
        XCTAssertNotNil(account.watcher)
        // The focused account's watch status is untouched.
        XCTAssertEqual(app.watchStatus, .idle)

        app.pauseWatching(account: account)
        XCTAssertEqual(account.watchStatus, .paused)

        app.stopWatching(account: account)
        XCTAssertEqual(account.watchStatus, .idle)
    }

    func testProviderRecoveryResumesBackgroundWatcherPausedByManagedAuth() {
        let (app, account) = makeAppState(fetch: .success([]))
        configureManagedProviderReady(app)
        account.watchStatus = .paused
        account.resumeWatchingAfterManagedReauth = true

        app.resumeInboxWatchingAfterProviderRecoveryIfNeeded()
        defer { app.stopWatching(account: account) }

        XCTAssertEqual(account.watchStatus, .watching)
        XCTAssertFalse(account.resumeWatchingAfterManagedReauth)
        XCTAssertNotNil(account.watcher)
    }

    func testProviderRecoveryStartsIdleBackgroundWatcherWhenReady() {
        let (app, account) = makeAppState(fetch: .success([]))
        configureManagedProviderReady(app)
        account.watchStatus = .idle

        app.resumeInboxWatchingAfterProviderRecoveryIfNeeded()
        defer { app.stopWatching(account: account) }

        XCTAssertEqual(account.watchStatus, .watching)
        XCTAssertNotNil(account.watcher)
    }

    func testAuthFailurePausesOnlyThatAccount() async {
        let (app, account) = makeAppState(fetch: .failure(.authenticationFailed("bad app password")))
        app.watchStatus = .watching
        account.watchStatus = .watching

        await app.pollInbox(account: account)

        XCTAssertEqual(account.watchStatus, .paused)
        XCTAssertNotNil(account.watchError)
        // The focused account keeps watching.
        XCTAssertEqual(app.watchStatus, .watching)
    }

    private func configureManagedProviderReady(_ app: AppState) {
        app.llmProviderKind = .managed
        app.verifiedLLMModel = LLMProviderKind.managed.defaultModel
        app.isLLMConnected = true
        app.isManagedSignedIn = true
        let status = ManagedAccountStatus(subscription: ManagedSubscription(plan: .pro, status: .active))
        app.managedAccountStatus = status
        app.markManagedAccountStatusFresh(from: status)
    }
}
