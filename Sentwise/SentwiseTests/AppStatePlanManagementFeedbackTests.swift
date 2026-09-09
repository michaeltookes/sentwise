import XCTest
@testable import Sentwise

@MainActor
final class AppStatePlanManagementFeedbackTests: XCTestCase {

    private final class FeedbackLLM: LLMProviding, @unchecked Sendable {
        var statusToReturn: ManagedAccountStatus?
        var statusesToReturn: [ManagedAccountStatus] = []
        var changeResult: PaddlePlanChange?

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws
            -> LLMResponse { LLMResponse(text: "") }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
            if !statusesToReturn.isEmpty {
                statusToReturn = statusesToReturn.removeFirst()
            }
            return statusToReturn
        }
        func fetchManagedQuota() async throws -> ManagedQuota? { statusToReturn?.quota }

        func changeManagedPlan(priceID: String, expectedAccountKey: String?) async throws -> PaddlePlanChange {
            if let changeResult { return changeResult }
            let plan = PaddleConfig.active.plan(forPriceID: priceID)?.subscriptionPlan ?? .unknown
            return PaddlePlanChange(plan: plan, status: .active)
        }
    }

    func testAuthoritativeSubscriptionChangeClearsStalePlanChangeConfirmation() async {
        let llm = FeedbackLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .pro, status: .active)
        appState.planChangeMessage = AppState.changePlanConfirmation(for: .pro)
        appState.planChangeConfirmationTier = .pro
        llm.statusToReturn = status(plan: .starter, status: .active, quota: quota(limit: 30))

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .starter)
        XCTAssertNil(appState.planChangeMessage)
        XCTAssertNil(appState.planChangeConfirmationTier)
        XCTAssertFalse(appState.planChangeFailed)
    }

    func testMissingSubscriptionClearsStalePlanChangeConfirmation() async {
        let llm = FeedbackLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .pro, status: .active)
        appState.planChangeMessage = AppState.changePlanConfirmation(for: .pro)
        appState.planChangeConfirmationTier = .pro
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: quota(limit: 0),
            subscription: nil
        )

        await appState.refreshManagedQuota()

        XCTAssertNil(appState.planChangeMessage)
        XCTAssertNil(appState.planChangeConfirmationTier)
        XCTAssertFalse(appState.planChangeFailed)
    }

    func testAuthoritativeDifferentSubscriptionClearsFailedPendingPlanChange() async {
        let llm = FeedbackLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .starter, status: .active)
        appState.pendingPlanChangeReconciliation = PendingPlanChangeReconciliation(
            tier: .pro,
            accountKey: appState.currentManagedUsageAccountKey,
            generation: appState.planChangeReconciliationGeneration
        )
        appState.planChangeFailed = true
        appState.planChangeMessage = AppState.changePlanConfirmationPendingMessage()
        appState.planChangeConfirmationTier = nil
        llm.statusToReturn = status(plan: .unlimited, status: .active, quota: quota(limit: 500))

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .unlimited)
        XCTAssertNil(appState.pendingPlanChangeReconciliation)
        XCTAssertNil(appState.planChangeMessage)
        XCTAssertNil(appState.planChangeConfirmationTier)
        XCTAssertFalse(appState.planChangeFailed)
    }

    func testImmediateQuotaLessPlanConfirmationKeepsRetryStaleUntilQuotaArrives() async {
        let llm = FeedbackLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer {
            appState.cancelScheduledManagedAccountStatusRefresh()
            appState.cancelPlanChangeReconciliation()
        }
        let quota = quota(limit: 120)
        setStatus(appState, plan: .starter, status: .active)
        llm.changeResult = PaddlePlanChange(plan: .pro, status: .active)
        llm.statusesToReturn = [
            status(plan: .pro, status: .active),
            status(plan: .pro, status: .active),
            status(plan: .pro, status: .active, quota: quota)
        ]

        await appState.changePlan(to: .pro, reconcileRetryDelays: [], backgroundReconcileRetryDelays: [])

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertNotNil(appState.pendingPlanChangeReconciliation)
        XCTAssertNotNil(appState.managedAccountStatusRefreshTask)

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertNotNil(appState.pendingPlanChangeReconciliation)
        XCTAssertNotNil(appState.managedAccountStatusRefreshTask)

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedQuota, quota)
        XCTAssertNil(appState.pendingPlanChangeReconciliation)
    }

    func testAuthoritativeMatchingSubscriptionKeepsPlanChangeConfirmation() async {
        let llm = FeedbackLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .pro, status: .active)
        appState.planChangeMessage = AppState.changePlanConfirmation(for: .pro)
        appState.planChangeConfirmationTier = .pro
        llm.statusToReturn = status(plan: .pro, status: .active, quota: quota(limit: 120))

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.planChangeMessage, AppState.changePlanConfirmation(for: .pro))
        XCTAssertEqual(appState.planChangeConfirmationTier, .pro)
        XCTAssertFalse(appState.planChangeFailed)
    }

    private func setStatus(_ appState: AppState, plan: ManagedSubscription.Plan, status: ManagedSubscription.Status) {
        let value = self.status(plan: plan, status: status)
        appState.managedAccountStatus = value
        appState.markManagedAccountStatusFresh(from: value)
    }

    private func status(
        plan: ManagedSubscription.Plan,
        status: ManagedSubscription.Status,
        quota: ManagedQuota? = nil
    ) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: quota,
            subscription: ManagedSubscription(plan: plan, status: status, renewsAt: nil, manageBillingURL: nil)
        )
    }

    private func quota(limit: Int) -> ManagedQuota {
        ManagedQuota(used: 1, limit: limit, remaining: limit - 1, resetsAt: Date(), tokenLimit: limit * 10)
    }

    private func makeSignedInAppState(llm: LLMProviding) -> AppState {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            managedAccountEmail: "marcus@example.com",
            managedAccountID: "clerk-user:user_marcus"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: FakeDraftNotifier()
        )
        appState.subscriptionCacheStore = InMemorySubscriptionCacheStore()
        return appState
    }

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        private var snapshots: [String: SubscriptionSnapshot] = [:]
        func snapshot(accountKey: String) -> SubscriptionSnapshot? { snapshots[accountKey] }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) { snapshots[accountKey] = snapshot }
        func clear(accountKey: String) { snapshots.removeValue(forKey: accountKey) }
    }
}
