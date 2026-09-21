import SentwiseMail
import XCTest
@testable import Sentwise

/// The tier-gated inbox-drafting policy (item 108): the Starter watcher gate, the
/// draft-on-click default, the opt-in automatic-drafting decision (global toggle +
/// auto-draft sender list), the monthly budget cap, and the reauth re-baseline.
@MainActor
final class AppStateInboxDraftingPolicyTests: XCTestCase {

    // MARK: - Fixtures

    private func message(
        id: UInt32,
        from: String = "alice@x.com",
        date: String = "",
        uidValidity: UInt32? = 10
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: uidValidity,
            from: MailAddress(name: "Alice", email: from),
            subject: "Subject \(id)",
            date: date,
            messageID: "<\(id)@x.com>"
        )
    }

    private func pendingDraft(
        id: UInt32,
        account: String = "me@gmail.com",
        host: String = "imap.gmail.com"
    ) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: account,
            sourceMailHost: host,
            sourceMailPort: 993,
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: "Subject \(id)",
            sourceFrom: MailAddress(name: "Alice", email: "alice@x.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<\(id)@x.com>",
            incomingBody: "Please advise.",
            replySubject: "Re: Subject \(id)",
            body: "On it.",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func baselineProcessed() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        return processed
    }

    private func makeAppState(
        plan: ManagedSubscription.Plan? = .pro,
        fetch: Result<[MailMessage], MailError> = .success([]),
        body: Result<Data, MailError> = .success(Data("Please advise.".utf8)),
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: "On it.")),
        processed: ProcessedMessages? = nil
    ) -> (AppState, FakeAppMailProvider, FakeDraftNotifier, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6"
            ),
            processedMessages: processed ?? baselineProcessed()
        )
        let provider = FakeAppMailProvider(result: .success(()), fetchResult: fetch, bodyResult: body)
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let notifier = FakeDraftNotifier()
        let appState = AppState(
            persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm, notifier: notifier
        )
        appState.retryRunner = .immediate
        appState.autoDraftBudgetStore = InMemoryAutoDraftBudgetStore()
        if let plan {
            appState.managedAccountStatus = ManagedAccountStatus(
                subscription: ManagedSubscription(plan: plan, status: .active)
            )
        }
        return (appState, provider, notifier, persistence)
    }

    // MARK: - Pure tier policy

    func testTierPolicyAllowsWatchingPerPlan() {
        XCTAssertFalse(InboxDraftingTierPolicy.allowsInboxWatching(for: .starter))
        XCTAssertTrue(InboxDraftingTierPolicy.allowsInboxWatching(for: .pro))
        XCTAssertTrue(InboxDraftingTierPolicy.allowsInboxWatching(for: .unlimited))
        XCTAssertTrue(InboxDraftingTierPolicy.allowsInboxWatching(for: .trial))
        // Reserved/unknown/none/nil are lenient (Pro-equivalent).
        XCTAssertTrue(InboxDraftingTierPolicy.allowsInboxWatching(for: .team))
        XCTAssertTrue(InboxDraftingTierPolicy.allowsInboxWatching(for: .noPlan))
        XCTAssertTrue(InboxDraftingTierPolicy.allowsInboxWatching(for: .unknown))
        XCTAssertTrue(InboxDraftingTierPolicy.allowsInboxWatching(for: nil))
    }

    func testSenderRulesMatchesAddressAndDomain() {
        let rules = [SenderRule(normalized: "boss@work.com"), SenderRule(normalized: "client.com")]
        XCTAssertTrue(SenderRules.matches(senderEmail: "boss@work.com", in: rules))
        XCTAssertTrue(SenderRules.matches(senderEmail: "anyone@client.com", in: rules))
        XCTAssertTrue(SenderRules.matches(senderEmail: "sales@mail.client.com", in: rules))
        XCTAssertFalse(SenderRules.matches(senderEmail: "someone@else.com", in: rules))
        XCTAssertFalse(SenderRules.matches(senderEmail: nil, in: rules))
    }

    func testSettingsNormalizedDedupesAndClampsBudget() {
        let settings = InboxDraftingSettings(
            autoDraftSenders: [SenderRule(normalized: "a@b.com"), SenderRule(normalized: "a@b.com")],
            monthlyAutoDraftBudget: -5
        ).normalized()
        XCTAssertEqual(settings.autoDraftSenders.count, 1)
        XCTAssertEqual(settings.monthlyAutoDraftBudget, 0)
    }

    // MARK: - Per-plan watcher gating

    func testStarterNeverStartsWatcher() {
        let (app, _, _, _) = makeAppState(plan: .starter)
        XCTAssertFalse(app.inboxWatchingAllowedForTier)
        XCTAssertFalse(app.canWatch)
        app.startWatchingIfReady()
        XCTAssertEqual(app.watchStatus, .idle)
        // No misleading "connect an account" error for a tier reason.
        XCTAssertNil(app.watchError)
    }

    func testStarterBackgroundAccountNeverWatches() {
        let (app, _, _, _) = makeAppState(plan: .starter)
        let background = ConnectedMailAccount(
            email: "side@work.com", host: "imap.work.com", port: 993, appPassword: "pw"
        )
        app.backgroundConnectedAccounts = [background]
        XCTAssertFalse(app.canWatch(account: background))
    }

    func testProStartsWatcher() {
        let (app, _, _, _) = makeAppState(plan: .pro)
        XCTAssertTrue(app.canWatch)
        app.startWatchingIfReady()
        XCTAssertEqual(app.watchStatus, .watching)
        app.stopWatching()
    }

    func testUnlimitedAndTrialStartWatcher() {
        for plan in [ManagedSubscription.Plan.unlimited, .trial] {
            let (app, _, _, _) = makeAppState(plan: plan)
            app.startWatchingIfReady()
            XCTAssertEqual(app.watchStatus, .watching, "\(plan) should watch")
            app.stopWatching()
        }
    }

    func testUnknownOfflinePlanAllowsWatching() {
        let (app, _, _, _) = makeAppState(plan: nil)
        XCTAssertNil(app.currentSubscriptionPlan)
        XCTAssertTrue(app.inboxWatchingAllowedForTier)
        app.startWatchingIfReady()
        XCTAssertEqual(app.watchStatus, .watching)
        app.stopWatching()
    }

    func testLiveDowngradeToStarterStopsWatcher() {
        let (app, _, _, _) = makeAppState(plan: .pro)
        app.startWatchingIfReady()
        XCTAssertEqual(app.watchStatus, .watching)
        app.managedAccountStatus = ManagedAccountStatus(
            subscription: ManagedSubscription(plan: .starter, status: .active)
        )
        app.enforceInboxWatchingTierGate()
        XCTAssertEqual(app.watchStatus, .idle)
    }

    func testLiveDowngradeToStarterStopsWatchersWithoutCancelingSendCountdowns() async {
        let (app, _, _, _) = makeAppState(plan: .pro)
        let focusedDraft = pendingDraft(id: 10)
        let backgroundDraft = pendingDraft(id: 11, account: "side@work.com", host: "imap.work.com")
        let background = ConnectedMailAccount(
            email: "side@work.com", host: "imap.work.com", port: 993, appPassword: "side-pw"
        )
        app.pendingDrafts = [focusedDraft, backgroundDraft]
        app.pendingDraftCount = app.pendingDrafts.count
        app.backgroundConnectedAccounts = [background]
        app.sendBehavior = .autoSend
        app.sendDelaySeconds = 30
        app.sendCountdownTickNanoseconds = 1_000_000_000
        app.watchStatus = .watching
        background.watchStatus = .watching

        await app.approveDraft(focusedDraft)
        await app.approveDraft(backgroundDraft)

        XCTAssertEqual(app.pendingSendCountdowns[focusedDraft.identity], 30)
        XCTAssertEqual(app.pendingSendCountdowns[backgroundDraft.identity], 30)

        app.managedAccountStatus = ManagedAccountStatus(
            subscription: ManagedSubscription(plan: .starter, status: .active)
        )
        app.enforceInboxWatchingTierGate()

        XCTAssertEqual(app.watchStatus, .idle)
        XCTAssertEqual(background.watchStatus, .idle)
        XCTAssertTrue(app.resumeWatchingAfterManagedReauth)
        XCTAssertEqual(app.pendingSendCountdowns[focusedDraft.identity], 30)
        XCTAssertEqual(app.pendingSendCountdowns[backgroundDraft.identity], 30)

        app.cancelAllSendCountdowns()
    }

    // MARK: - Manual drafting stays on Starter

    func testStarterKeepsManualOnDemandDrafting() async {
        let (app, provider, _, _) = makeAppState(plan: .starter)
        let draft = await app.generateDraft(for: message(id: 1))
        XCTAssertNotNil(draft)
        XCTAssertEqual(draft?.body, "On it.")
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
    }

    // MARK: - Draft-on-click default

    func testDraftOnClickCreatesAwaitingEntryWithoutGeneration() async {
        let (app, provider, notifier, _) = makeAppState(plan: .pro, fetch: .success([message(id: 1)]))
        XCTAssertFalse(app.inboxDrafting.autoDraftEnabled)
        app.watchStatus = .watching
        await app.pollInboxOnce()

        XCTAssertEqual(app.pendingDrafts.count, 1)
        XCTAssertTrue(app.pendingDrafts[0].isAwaitingDraftRequest)
        XCTAssertTrue(app.pendingDrafts[0].body.isEmpty)
        // No generation happened — the credit is not spent until the user clicks.
        XCTAssertEqual(provider.bodyFetchCallCount, 0)
        // The notification is worded as an offer (an awaiting entry).
        XCTAssertEqual(notifier.notifiedDrafts.last?.isAwaitingDraftRequest, true)
    }

    func testClickingDraftGeneratesExactlyOnce() async throws {
        let (app, provider, _, _) = makeAppState(plan: .pro, fetch: .success([message(id: 1)]))
        app.watchStatus = .watching
        await app.pollInboxOnce()
        let awaiting = try XCTUnwrap(app.pendingDrafts.first)
        XCTAssertEqual(provider.bodyFetchCallCount, 0)
        XCTAssertTrue(app.activityEvents.isEmpty)

        await app.draftAwaitingRequest(awaiting)

        XCTAssertEqual(provider.bodyFetchCallCount, 1, "clicking Draft generates exactly once")
        XCTAssertEqual(app.pendingDrafts.count, 1)
        XCTAssertFalse(app.pendingDrafts[0].isAwaitingDraftRequest)
        XCTAssertEqual(app.pendingDrafts[0].body, "On it.")
        XCTAssertEqual(app.activityEvents.map(\.kind), [.draftCreated])
        XCTAssertEqual(app.activityEvents.first?.subject, "Subject 1")
    }

    // MARK: - Automatic drafting opt-in

    func testAutoToggleOnGeneratesOnPoll() async {
        let (app, provider, _, _) = makeAppState(plan: .pro, fetch: .success([message(id: 1)]))
        app.inboxDrafting.autoDraftEnabled = true
        app.watchStatus = .watching
        await app.pollInboxOnce()

        XCTAssertEqual(app.pendingDrafts.count, 1)
        XCTAssertFalse(app.pendingDrafts[0].isAwaitingDraftRequest)
        XCTAssertEqual(app.pendingDrafts[0].body, "On it.")
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
    }

    func testAutoDraftSenderListGeneratesEvenWhenToggleOff() async {
        let (app, provider, _, _) = makeAppState(
            plan: .pro, fetch: .success([message(id: 1, from: "vip@client.com")])
        )
        app.inboxDrafting.autoDraftEnabled = false
        app.inboxDrafting.autoDraftSenders = [SenderRule(normalized: "client.com")]
        app.watchStatus = .watching
        await app.pollInboxOnce()

        XCTAssertEqual(app.pendingDrafts.count, 1)
        XCTAssertFalse(app.pendingDrafts[0].isAwaitingDraftRequest, "listed sender auto-drafts")
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
    }

    func testUnlistedSenderStaysDraftOnClick() async {
        let (app, provider, _, _) = makeAppState(
            plan: .pro, fetch: .success([message(id: 1, from: "stranger@other.com")])
        )
        app.inboxDrafting.autoDraftEnabled = false
        app.inboxDrafting.autoDraftSenders = [SenderRule(normalized: "client.com")]
        app.watchStatus = .watching
        await app.pollInboxOnce()

        XCTAssertEqual(app.pendingDrafts.count, 1)
        XCTAssertTrue(app.pendingDrafts[0].isAwaitingDraftRequest, "unlisted sender stays draft-on-click")
        XCTAssertEqual(provider.bodyFetchCallCount, 0)
    }

    // MARK: - Monthly budget cap

    func testBudgetCapFallsBackToDraftOnClick() async {
        let (app, provider, notifier, _) = makeAppState(
            plan: .pro,
            fetch: .success([message(id: 2), message(id: 1)])  // newest first; poll processes oldest first
        )
        app.managedQuota = ManagedQuota(limit: 100, resetsAt: Date().addingTimeInterval(86_400 * 10))
        app.inboxDrafting.autoDraftEnabled = true
        app.inboxDrafting.monthlyAutoDraftBudget = 1
        app.watchStatus = .watching
        await app.pollInboxOnce()

        XCTAssertEqual(app.pendingDrafts.count, 2)
        let generated = app.pendingDrafts.filter { !$0.isAwaitingDraftRequest }
        let awaiting = app.pendingDrafts.filter { $0.isAwaitingDraftRequest }
        XCTAssertEqual(generated.count, 1, "only the budget's worth auto-generates")
        XCTAssertEqual(awaiting.count, 1, "the rest fall back to draft-on-click")
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.hundred], "cap surfaces a usage alert once")
        XCTAssertTrue(app.isAutoDraftBudgetExhausted)
    }

    func testModelSkippedAutoDraftCountsAgainstBudget() async {
        let modelSkipped = "\(DraftGenerator.notReplyWorthySentinel) This looks automated."
        let (app, provider, _, _) = makeAppState(
            plan: .pro,
            fetch: .success([message(id: 1)]),
            completion: .success(LLMResponse(text: modelSkipped))
        )
        app.managedQuota = ManagedQuota(limit: 100, resetsAt: Date().addingTimeInterval(86_400 * 10))
        app.inboxDrafting.autoDraftEnabled = true
        app.inboxDrafting.monthlyAutoDraftBudget = 1
        app.watchStatus = .watching

        await app.pollInboxOnce()

        XCTAssertTrue(app.pendingDrafts.isEmpty)
        XCTAssertEqual(app.skippedMessages.map(\.reason), [.notReplyWorthyPerModel])
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
        XCTAssertEqual(app.autoDraftUsedThisWindow, 1)
        XCTAssertTrue(app.isAutoDraftBudgetExhausted)
    }

    func testAutoDraftBudgetReservationRefusesSecondClaimAtCap() {
        let (app, _, notifier, _) = makeAppState(plan: .pro)
        app.managedQuota = ManagedQuota(limit: 100, resetsAt: Date().addingTimeInterval(86_400 * 10))
        app.inboxDrafting.monthlyAutoDraftBudget = 1

        XCTAssertTrue(app.reserveAutoDraftBudgetUsageIfAvailable())
        XCTAssertFalse(app.reserveAutoDraftBudgetUsageIfAvailable())

        XCTAssertEqual(app.autoDraftUsedThisWindow, 1)
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.hundred])
    }

    func testBudgetCapDoesNotAffectManualDrafting() async {
        let (app, provider, _, _) = makeAppState(plan: .pro)
        app.managedQuota = ManagedQuota(limit: 100, resetsAt: Date().addingTimeInterval(86_400 * 10))
        app.inboxDrafting.autoDraftEnabled = true
        app.inboxDrafting.monthlyAutoDraftBudget = 0  // exhausted immediately
        XCTAssertTrue(app.isAutoDraftBudgetExhausted)

        let draft = await app.generateDraft(for: message(id: 1))
        XCTAssertNotNil(draft, "manual drafting ignores the auto-draft budget cap")
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
    }

    // MARK: - Awaiting entries are never dispatchable

    func testAwaitingEntryIsNotApprovable() async throws {
        let (app, provider, _, _) = makeAppState(plan: .pro, fetch: .success([message(id: 1)]))
        app.watchStatus = .watching
        await app.pollInboxOnce()
        let awaiting = try XCTUnwrap(app.pendingDrafts.first)

        await app.approveDraft(awaiting)
        XCTAssertNotNil(app.approvalError)
        XCTAssertEqual(provider.appendedRFC822, nil)
        XCTAssertEqual(app.pendingDrafts.count, 1, "the awaiting entry stays queued")
    }

    func testDismissAwaitingRemovesEntry() async throws {
        let (app, _, _, _) = makeAppState(plan: .pro, fetch: .success([message(id: 1)]))
        app.watchStatus = .watching
        await app.pollInboxOnce()
        let awaiting = try XCTUnwrap(app.pendingDrafts.first)
        app.dismissAwaitingRequestDraft(awaiting)
        XCTAssertTrue(app.pendingDrafts.isEmpty)
    }

    // MARK: - Reauth re-baseline

    func testResetBaselineClearsMarkers() {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        processed.setBaselineStart(account: "me@gmail.com", mailbox: .inbox, date: Date())
        processed.setBaselineUID(account: "me@gmail.com", mailbox: .inbox, uid: 5, uidValidity: 10)
        processed.resetBaseline(account: "me@gmail.com", mailbox: .inbox)
        XCTAssertFalse(processed.hasBaseline(account: "me@gmail.com", mailbox: .inbox))
        XCTAssertFalse(processed.hasBaselineStart(account: "me@gmail.com", mailbox: .inbox))
        XCTAssertNil(processed.baselineUID(account: "me@gmail.com", mailbox: .inbox))
    }

    func testReauthRebaselineDropsBacklog() async {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        processed.setBaselineUID(account: "me@gmail.com", mailbox: .inbox, uid: 1, uidValidity: 10)
        // Backlog that accumulated while signed out (would otherwise be replayed).
        let backlog = [
            message(id: 3, date: "Tue, 14 Nov 2023 22:13:19 +0000"),
            message(id: 2, date: "Tue, 14 Nov 2023 22:13:18 +0000")
        ]
        let (app, provider, _, _) = makeAppState(plan: .pro, fetch: .success(backlog), processed: processed)
        app.inboxDrafting.autoDraftEnabled = true

        app.rebaselineInboxForManagedReauth(account: nil)
        app.recordWatcherBaselineStartIfNeeded(account: "me@gmail.com", mailbox: .inbox, date: Date())
        app.watchStatus = .watching
        await app.pollInboxOnce()

        XCTAssertTrue(app.pendingDrafts.isEmpty, "the accumulated backlog is not replayed after reauth")
        XCTAssertEqual(provider.bodyFetchCallCount, 0)
    }

    // MARK: - Migration

    func testMigrationDefaultsToDraftOnClickAndDoesNotPromoteAllowlist() throws {
        // A pre-108 (v22) file with an allowlist entry and no inboxDrafting key.
        let legacy = """
        {"schemaVersion":22,"pollIntervalSeconds":300,"mailEmail":"me@gmail.com",
         "senderAllowlist":[{"pattern":"boss@work.com"}]}
        """
        let loaded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        let secrets = InMemorySecretStore()
        let persistence = AppStateMemoryPersistence(settings: loaded)
        let migrated = AppState.fullyMigratedSettings(loaded: loaded, secrets: secrets, persistence: persistence)

        XCTAssertEqual(migrated.schemaVersion, Settings.inboxDraftingPolicySchemaVersion)
        XCTAssertFalse(migrated.inboxDrafting.autoDraftEnabled, "existing installs default to draft-on-click")
        XCTAssertTrue(migrated.inboxDrafting.autoDraftSenders.isEmpty, "allowlist entries are not promoted to auto-draft")
        XCTAssertEqual(migrated.senderAllowlist.map(\.pattern), ["boss@work.com"], "the allowlist itself is preserved")
    }
}

/// In-memory auto-draft budget store for tests (item 108).
final class InMemoryAutoDraftBudgetStore: AutoDraftBudgetStoring, @unchecked Sendable {
    private var states: [String: AutoDraftBudgetState] = [:]
    func loadState(for accountKey: String) -> AutoDraftBudgetState? { states[accountKey] }
    func save(_ state: AutoDraftBudgetState) { states[state.accountKey] = state }
    func clearAll() { states.removeAll() }
}
