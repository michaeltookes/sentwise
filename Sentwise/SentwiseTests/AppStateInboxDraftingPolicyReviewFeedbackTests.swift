import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class InboxDraftingReviewFeedbackTests: XCTestCase {

    private func message(id: UInt32) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 10,
            from: MailAddress(name: "Alice", email: "alice@x.com"),
            subject: "Subject \(id)",
            date: "",
            messageID: "<\(id)@x.com>"
        )
    }

    private func baselineProcessed() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        return processed
    }

    private func makeAppState(
        plan: ManagedSubscription.Plan? = .pro,
        fetch: Result<[MailMessage], MailError> = .success([])
    ) -> (AppState, FakeAppMailProvider, FakeDraftNotifier) {
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
            processedMessages: baselineProcessed()
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: fetch,
            bodyResult: .success(Data("Please advise.".utf8))
        )
        let notifier = FakeDraftNotifier()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "On it."))),
            notifier: notifier
        )
        appState.retryRunner = .immediate
        appState.autoDraftBudgetStore = InMemoryAutoDraftBudgetStore()
        if let plan {
            appState.managedAccountStatus = ManagedAccountStatus(
                subscription: ManagedSubscription(plan: plan, status: .active)
            )
        }
        return (appState, provider, notifier)
    }

    func testBudgetCapFallsBackToDraftOnClickWithoutManagedQuota() async {
        let (app, provider, notifier) = makeAppState(
            plan: nil,
            fetch: .success([message(id: 2), message(id: 1)])
        )
        app.inboxDrafting.autoDraftEnabled = true
        app.inboxDrafting.monthlyAutoDraftBudget = 1
        app.watchStatus = .watching

        await app.pollInboxOnce()

        XCTAssertEqual(app.pendingDrafts.count, 2)
        XCTAssertEqual(app.pendingDrafts.filter { !$0.isAwaitingDraftRequest }.count, 1)
        XCTAssertEqual(app.pendingDrafts.filter(\.isAwaitingDraftRequest).count, 1)
        XCTAssertEqual(app.pendingDrafts.first(where: \.isAwaitingDraftRequest)?.incomingBody, "Please advise.")
        XCTAssertEqual(provider.bodyFetchCallCount, 2)
        XCTAssertEqual(app.autoDraftUsedThisWindow, 1)
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.hundred])
        XCTAssertTrue(app.isAutoDraftBudgetExhausted)
    }

    func testManagedQuotaWindowPreservesFallbackBudgetUsage() {
        let (app, _, notifier) = makeAppState(plan: .pro)
        app.isManagedSignedIn = true
        app.managedAccountID = "user_marcus"
        app.managedQuota = nil
        app.inboxDrafting.monthlyAutoDraftBudget = 1

        XCTAssertTrue(app.reserveAutoDraftBudgetUsageIfAvailable())
        XCTAssertEqual(app.autoDraftUsedThisWindow, 1)

        app.managedQuota = ManagedQuota(limit: 100, resetsAt: Date().addingTimeInterval(86_400 * 10))

        XCTAssertEqual(app.autoDraftUsedThisWindow, 1)
        XCTAssertTrue(app.isAutoDraftBudgetExhausted)
        XCTAssertFalse(app.reserveAutoDraftBudgetUsageIfAvailable())
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.hundred])
    }

    func testLiveDowngradeKeepsUserPausedBackgroundWatchersPaused() {
        let (app, _, _) = makeAppState(plan: .pro)
        let pausedBackground = ConnectedMailAccount(
            email: "side@work.com", host: "imap.work.com", port: 993, appPassword: "side-pw"
        )
        app.backgroundConnectedAccounts = [pausedBackground]
        pausedBackground.watchStatus = .paused

        app.managedAccountStatus = ManagedAccountStatus(
            subscription: ManagedSubscription(plan: .starter, status: .active)
        )
        app.enforceInboxWatchingTierGate()

        XCTAssertEqual(pausedBackground.watchStatus, .paused)
        XCTAssertFalse(pausedBackground.resumeWatchingAfterManagedReauth)

        app.managedAccountStatus = ManagedAccountStatus(
            subscription: ManagedSubscription(plan: .pro, status: .active)
        )
        app.resumeBackgroundInboxWatchingAfterProviderRecoveryIfNeeded()

        XCTAssertEqual(pausedBackground.watchStatus, .paused)
    }
}
