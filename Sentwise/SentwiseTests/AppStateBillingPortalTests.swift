import XCTest
@testable import Sentwise

@MainActor
final class AppStateBillingPortalTests: XCTestCase {
    private final class StatusLLM: LLMProviding, @unchecked Sendable {
        var statusToReturn: ManagedAccountStatus?
        /// The fresh management URL returned by the on-demand endpoint (item 90).
        var manageBillingURLToReturn = URL(string: "https://billing.example/fresh")!
        var manageBillingError: Error?
        private(set) var manageBillingFetchCount = 0
        private(set) var changePlanCount = 0

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws
            -> LLMResponse {
            LLMResponse(text: "")
        }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? { statusToReturn }
        func fetchManagedQuota() async throws -> ManagedQuota? { statusToReturn?.quota }
        func deleteManagedAccount() async throws {}
        func fetchManageBillingURL(action: PaddleBillingAction?) async throws -> URL {
            manageBillingFetchCount += 1
            if let manageBillingError { throw manageBillingError }
            return manageBillingURLToReturn
        }
        func changeManagedPlan(priceID: String, expectedAccountKey: String?) async throws -> PaddlePlanChange {
            changePlanCount += 1
            throw LLMError.managedNotSignedIn
        }
    }

    func testOpenManageBillingFetchesFreshURLOnDemandIgnoringStoredAndCachedURLs() async {
        let llm = StatusLLM()
        llm.manageBillingURLToReturn = URL(string: "https://billing.example/fresh")!
        let appState = makeSignedInAppState(llm: llm)
        // A paid subscription with NO stored billing URL — the item-90 bug where
        // the enabled button used to no-op. A stale cached URL must be ignored too.
        appState.managedAccountStatus = status(plan: .pro, statusValue: .active, billingURL: nil)
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .active,
            manageBillingURL: "https://billing.example/stale",
            capturedAt: Date().addingTimeInterval(-3 * 86_400)
        )
        var openedURL: URL?

        XCTAssertTrue(appState.canManageBilling)
        XCTAssertNil(appState.manageBillingURL)

        await appState.openManageBilling { openedURL = $0 }

        XCTAssertEqual(llm.manageBillingFetchCount, 1)
        XCTAssertEqual(openedURL?.absoluteString, "https://billing.example/fresh")
        XCTAssertTrue(appState.billingPortalRefreshPending)
        XCTAssertNil(appState.manageBillingMessage)
    }

    func testOpenManageBillingSurfacesMessageAndDoesNotOpenOnFailure() async {
        let llm = StatusLLM()
        llm.manageBillingError = LLMError.managedManageBillingUnavailable("No active subscription to manage.")
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(plan: .pro, statusValue: .active, billingURL: nil)
        var openedURL: URL?

        XCTAssertTrue(appState.canManageBilling)

        await appState.openManageBilling { openedURL = $0 }

        XCTAssertEqual(llm.manageBillingFetchCount, 1)
        XCTAssertNil(openedURL, "an enabled button must never silently no-op — no open on failure")
        XCTAssertEqual(appState.manageBillingMessage, "No active subscription to manage.")
        XCTAssertFalse(appState.billingPortalRefreshPending)
        XCTAssertFalse(appState.isManagingBilling)
    }

    func testCanManageBillingIsFalseDuringPlanChange() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(plan: .pro, statusValue: .active, billingURL: nil)
        appState.isChangingPlan = true

        XCTAssertFalse(appState.canManageBilling)
    }

    func testChangePlanIsNoOpWhileManageBillingIsInFlight() async {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(plan: .starter, statusValue: .active, billingURL: nil)
        appState.isManagingBilling = true

        await appState.changePlan(to: .pro)

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .starter)
        XCTAssertNil(appState.planChangeMessage)
    }

    func testUnknownPaidLifecycleKeepsBillingPortalButBlocksPlanSwitching() async {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(plan: .pro, statusValue: .unknown, billingURL: nil)

        XCTAssertTrue(appState.hasManageablePaidSubscription)
        XCTAssertTrue(appState.canManageBilling)
        XCTAssertFalse(appState.showsPlanManagement)
        XCTAssertFalse(appState.canChangeManagedPlan)

        await appState.changePlan(to: .unlimited)

        XCTAssertEqual(llm.changePlanCount, 0)
        XCTAssertNil(appState.planChangeMessage)
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

    private func status(
        plan: ManagedSubscription.Plan,
        statusValue: ManagedSubscription.Status,
        billingURL: String?
    ) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: plan, status: statusValue, manageBillingURL: billingURL)
        )
    }

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        private var snapshots: [String: SubscriptionSnapshot] = [:]

        func snapshot(accountKey: String) -> SubscriptionSnapshot? { snapshots[accountKey] }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) { snapshots[accountKey] = snapshot }
        func clear(accountKey: String) { snapshots.removeValue(forKey: accountKey) }
    }
}
