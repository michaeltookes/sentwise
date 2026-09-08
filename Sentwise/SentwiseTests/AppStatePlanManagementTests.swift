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

        // Manage billing
        var manageBillingURLToReturn = URL(string: "https://billing.example/portal")!
        var manageBillingError: Error?
        private(set) var manageBillingActions: [PaddleBillingAction?] = []

        // Change plan
        var changeError: Error?
        /// The status the account flips to once a change succeeds; the reconcile
        /// poll reads it via `fetchManagedAccountStatus`.
        var statusAfterChange: ManagedAccountStatus?
        private(set) var changedPriceIDs: [String] = []

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws
            -> LLMResponse { LLMResponse(text: "") }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? { statusToReturn }
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

    private func status(plan: ManagedSubscription.Plan, status: ManagedSubscription.Status) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: plan, status: status, renewsAt: nil, manageBillingURL: nil)
        )
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
