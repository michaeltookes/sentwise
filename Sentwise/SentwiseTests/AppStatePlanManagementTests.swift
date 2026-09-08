import XCTest
@testable import Sentwise

/// AppState coverage for item 90: the on-demand manage-billing fetch/open, the
/// upgrade/downgrade change-plan flow with `/v1/me` reconciliation, cancel
/// routing, and the current-tier / catalog helpers.
@MainActor
final class AppStatePlanManagementTests: XCTestCase {

    /// A controllable `LLMProviding` double that records the plan-management calls
    /// and lets a test drive the account status the reconcile poll reads back.
    private final class PlanLLM: LLMProviding, @unchecked Sendable {
        var statusToReturn: ManagedAccountStatus?
        var statusesToReturn: [ManagedAccountStatus] = []

        // Manage billing
        var manageBillingURLToReturn = URL(string: "https://billing.example/portal")!
        var manageBillingError: Error?
        private(set) var manageBillingActions: [PaddleBillingAction?] = []

        // Change plan
        var changeError: Error?
        /// The status the account flips to once a change succeeds; the reconcile
        /// poll reads it via `fetchManagedAccountStatus`.
        var statusAfterChange: ManagedAccountStatus?
        var changeResult: PaddlePlanChange?
        private(set) var changedPriceIDs: [String] = []

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
        func deleteManagedAccount() async throws {}

        func fetchManageBillingURL(action: PaddleBillingAction?) async throws -> URL {
            manageBillingActions.append(action)
            if let manageBillingError { throw manageBillingError }
            return manageBillingURLToReturn
        }

        func changeManagedPlan(priceID: String) async throws -> PaddlePlanChange {
            changedPriceIDs.append(priceID)
            if let changeError { throw changeError }
            if let statusAfterChange { statusToReturn = statusAfterChange }
            if let changeResult { return changeResult }
            let plan = PaddleConfig.active.plan(forPriceID: priceID)?.subscriptionPlan ?? .unknown
            return PaddlePlanChange(plan: plan, status: .active)
        }
    }

    // MARK: - Manage billing (dead-button fix)

    func testCanManageBillingIsTrueForPaidAccountWithNoStoredURL() {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .pro, status: .active) // manageBillingURL nil (the bug)

        XCTAssertNil(appState.manageBillingURL)
        XCTAssertTrue(appState.canManageBilling)
    }

    func testOpenManageBillingFetchesFreshURLOnDemandAndOpensIt() async {
        let llm = PlanLLM()
        llm.manageBillingURLToReturn = URL(string: "https://billing.example/fresh")!
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .pro, status: .active)
        var openedURL: URL?

        await appState.openManageBilling { openedURL = $0 }

        XCTAssertEqual(llm.manageBillingActions, [nil])
        XCTAssertEqual(openedURL?.absoluteString, "https://billing.example/fresh")
        XCTAssertTrue(appState.billingPortalRefreshPending)
        XCTAssertFalse(appState.isManagingBilling)
        XCTAssertNil(appState.manageBillingMessage)
    }

    func testOpenManageBillingSurfacesMessageAndDoesNotOpenOnFailure() async {
        let llm = PlanLLM()
        llm.manageBillingError = LLMError.managedManageBillingUnavailable("No active subscription to manage.")
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .pro, status: .active)
        var openedURL: URL?

        await appState.openManageBilling { openedURL = $0 }

        XCTAssertNil(openedURL, "must never silently no-op an enabled button — no open on failure")
        XCTAssertEqual(appState.manageBillingMessage, "No active subscription to manage.")
        XCTAssertFalse(appState.isManagingBilling)
        XCTAssertFalse(appState.billingPortalRefreshPending)
    }

    func testCancelSubscriptionRoutesThroughCancelActionAndOpensURL() async {
        let llm = PlanLLM()
        llm.manageBillingURLToReturn = URL(string: "https://billing.example/cancel")!
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .pro, status: .active)
        var openedURL: URL?

        await appState.cancelSubscription { openedURL = $0 }

        XCTAssertEqual(llm.manageBillingActions, [.cancel])
        XCTAssertEqual(openedURL?.absoluteString, "https://billing.example/cancel")
    }

    // MARK: - Change plan (upgrade / downgrade)

    func testChangePlanUpgradesAndReconcilesToNewTier() async {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .starter, status: .active)
        llm.statusAfterChange = status(plan: .pro, status: .active)

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .starter)

        await appState.changePlan(to: .pro)

        XCTAssertEqual(llm.changedPriceIDs, [PaddleConfig.active.priceID(for: .pro)])
        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro, "reconcile should flip the pane to the new tier")
        XCTAssertEqual(appState.planChangeMessage, AppState.changePlanConfirmation(for: .pro))
        XCTAssertFalse(appState.planChangeFailed)
        XCTAssertFalse(appState.isChangingPlan)
        XCTAssertNil(appState.changingPlanTier)
    }

    func testChangePlanAppliesValidatedResponseWhenStatusPollDoesNotFlipTier() async {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .starter, status: .active)
        llm.changeResult = PaddlePlanChange(plan: .pro, status: .active)

        await appState.changePlan(
            to: .pro,
            reconcileRetryDelays: [],
            backgroundReconcileRetryDelays: [1_000_000_000]
        )

        XCTAssertEqual(llm.changedPriceIDs, [PaddleConfig.active.priceID(for: .pro)])
        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.plan, .pro)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertNotNil(appState.planChangeReconciliationTask)
        XCTAssertEqual(appState.planChangeMessage, AppState.changePlanConfirmation(for: .pro))
        XCTAssertFalse(appState.planChangeFailed)
        appState.cancelPlanChangeReconciliation()
    }

    func testPlanChangeBackgroundReconciliationMarksFreshWhenTargetQuotaArrives() async {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)
        let quota = ManagedQuota(used: 4, limit: 120, remaining: 116, resetsAt: Date(), tokenLimit: 1_200)
        setStatus(appState, plan: .starter, status: .active)
        llm.changeResult = PaddlePlanChange(plan: .pro, status: .active)
        llm.statusesToReturn = [
            status(plan: .starter, status: .active),
            status(plan: .pro, status: .active, quota: quota)
        ]

        await appState.changePlan(to: .pro, reconcileRetryDelays: [], backgroundReconcileRetryDelays: [0])
        await waitUntil { appState.planChangeReconciliationTask == nil }

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedQuota, quota)
    }

    func testChangePlanDoesNotConfirmWhenResponseAndPollMissTargetTier() async {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .starter, status: .active)
        llm.changeResult = PaddlePlanChange(plan: .starter, status: .active)

        await appState.changePlan(to: .pro, reconcileRetryDelays: [])

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .starter)
        XCTAssertTrue(appState.planChangeFailed)
        XCTAssertEqual(appState.planChangeMessage, AppState.changePlanConfirmationPendingMessage())
    }

    func testChangePlanDoesNotApplyResponseAfterAccountChangesDuringPoll() async {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .starter, status: .active)
        llm.changeResult = PaddlePlanChange(plan: .pro, status: .active)

        let change = Task {
            await appState.changePlan(
                to: .pro,
                reconcileRetryDelays: [200_000_000],
                backgroundReconcileRetryDelays: []
            )
        }
        await waitUntil { appState.isChangingPlan }
        let otherAccount = status(
            plan: .starter,
            status: .active,
            userID: "user_other",
            email: "other@example.com"
        )
        appState.managedAccountID = "clerk-user:user_other"
        appState.managedAccountEmail = "other@example.com"
        appState.managedAccountStatus = otherAccount
        appState.markManagedAccountStatusFresh(from: otherAccount)

        await change.value

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .starter)
        XCTAssertNil(appState.planChangeMessage)
        XCTAssertFalse(appState.planChangeFailed)
    }

    func testChangePlanIsNoOpWhenAlreadyOnTargetTier() async {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .pro, status: .active)

        await appState.changePlan(to: .pro)

        XCTAssertTrue(llm.changedPriceIDs.isEmpty)
        XCTAssertNil(appState.planChangeMessage)
    }

    func testChangePlanMapsEndpointErrorToFriendlyMessageAndDoesNotFlipTier() async {
        let llm = PlanLLM()
        llm.changeError = LLMError.managedChangePlanFailed("Plan changes are unavailable right now.")
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .starter, status: .active)

        await appState.changePlan(to: .unlimited)

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .starter)
        XCTAssertTrue(appState.planChangeFailed)
        XCTAssertEqual(appState.planChangeMessage, "Plan changes are unavailable right now.")
        XCTAssertFalse(appState.isChangingPlan)
    }

    func testChangePlanIsNoOpWhenPaidSubscriptionEnded() async {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .pro, status: .canceled)

        await appState.changePlan(to: .unlimited)

        XCTAssertTrue(llm.changedPriceIDs.isEmpty)
        XCTAssertNil(appState.planChangeMessage)
    }

    // MARK: - Current tier + catalog helpers

    func testCurrentSubscriptionPlanTierMapsEachPaidPlanAndNilsLifecyclePlans() {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)

        setStatus(appState, plan: .starter, status: .active)
        XCTAssertEqual(appState.currentSubscriptionPlanTier, .starter)
        setStatus(appState, plan: .unlimited, status: .active)
        XCTAssertEqual(appState.currentSubscriptionPlanTier, .unlimited)

        setStatus(appState, plan: .trial, status: .trialing)
        XCTAssertNil(appState.currentSubscriptionPlanTier)
        XCTAssertFalse(appState.showsPlanManagement)
    }

    func testPlanManagementHiddenForEndedPaidSubscriptions() {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)

        setStatus(appState, plan: .pro, status: .canceled)
        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertFalse(appState.hasManageablePaidSubscription)
        XCTAssertTrue(appState.shouldOfferSubscribe)
        XCTAssertFalse(appState.showsPlanManagement)

        setStatus(appState, plan: .unlimited, status: .lapsed)
        XCTAssertEqual(appState.currentSubscriptionPlanTier, .unlimited)
        XCTAssertFalse(appState.hasManageablePaidSubscription)
        XCTAssertTrue(appState.shouldOfferSubscribe)
        XCTAssertFalse(appState.showsPlanManagement)
    }

    func testClearingManagedAccountStateResetsBillingFeedback() {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.isManagingBilling = true
        appState.manageBillingMessage = "No active subscription to manage."
        appState.isChangingPlan = true
        appState.changingPlanTier = .pro
        appState.planChangeMessage = AppState.changePlanConfirmation(for: .pro)
        appState.planChangeFailed = true
        appState.billingPortalRefreshPending = true
        appState.planChangeReconciliationTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        appState.clearManagedQuotaCache()

        XCTAssertFalse(appState.isManagingBilling)
        XCTAssertNil(appState.manageBillingMessage)
        XCTAssertFalse(appState.isChangingPlan)
        XCTAssertNil(appState.changingPlanTier)
        XCTAssertNil(appState.planChangeMessage)
        XCTAssertFalse(appState.planChangeFailed)
        XCTAssertFalse(appState.billingPortalRefreshPending)
        XCTAssertNil(appState.planChangeReconciliationTask)
    }

    func testPlanCatalogValuesMatchOwnerConfirmedPricing() {
        XCTAssertEqual(PaddlePlan.starter.monthlyPrice, "$9")
        XCTAssertEqual(PaddlePlan.pro.monthlyPrice, "$19")
        XCTAssertEqual(PaddlePlan.unlimited.monthlyPrice, "$39")
        XCTAssertEqual(PaddlePlan.starter.allowanceSummary, "30 follow-ups a month")
        XCTAssertEqual(PaddlePlan.pro.allowanceSummary, "120 follow-ups a month")
        XCTAssertEqual(PaddlePlan.unlimited.allowanceSummary, "Unlimited follow-ups")
        XCTAssertTrue(PaddlePlan.pro.isFeatured)
        XCTAssertFalse(PaddlePlan.starter.isFeatured)
    }

    func testUpgradeDowngradeLadder() {
        XCTAssertTrue(PaddlePlan.pro.isUpgrade(from: .starter))
        XCTAssertTrue(PaddlePlan.unlimited.isUpgrade(from: .pro))
        XCTAssertFalse(PaddlePlan.starter.isUpgrade(from: .pro))
        XCTAssertFalse(PaddlePlan.pro.isUpgrade(from: .unlimited))
    }

    func testChangePlanPromptReadsUpgradeVsSwitch() {
        let llm = PlanLLM()
        let appState = makeSignedInAppState(llm: llm)
        setStatus(appState, plan: .starter, status: .active)
        XCTAssertEqual(appState.changePlanPrompt(for: .pro),
                       "Upgrade to Pro? Your plan changes now, prorated.")
        XCTAssertEqual(appState.changePlanPrompt(for: .starter),
                       "Switch to Starter? Your plan changes now, prorated.")
    }

    // MARK: - Helpers

    private func setStatus(_ appState: AppState, plan: ManagedSubscription.Plan, status: ManagedSubscription.Status) {
        let value = self.status(plan: plan, status: status)
        appState.managedAccountStatus = value
        appState.markManagedAccountStatusFresh(from: value)
    }

    private func status(
        plan: ManagedSubscription.Plan,
        status: ManagedSubscription.Status,
        userID: String = "user_marcus",
        email: String = "marcus@example.com",
        quota: ManagedQuota? = nil
    ) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: userID,
            email: email,
            quota: quota,
            subscription: ManagedSubscription(plan: plan, status: status, renewsAt: nil, manageBillingURL: nil)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), file: file, line: line)
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
