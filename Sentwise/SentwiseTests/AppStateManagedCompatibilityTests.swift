import XCTest
@testable import Sentwise

@MainActor
final class AppStateManagedCompatibilityTests: XCTestCase {

    private final class StatusLLM: LLMProviding, @unchecked Sendable {
        var statusToReturn: ManagedAccountStatus?

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
            LLMResponse(text: "")
        }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? { statusToReturn }
        func fetchManagedQuota() async throws -> ManagedQuota? { statusToReturn?.quota }
        func deleteManagedAccount() async throws {}
    }

    private func makeSignedInAppState(
        llm: LLMProviding,
        cacheStore: SubscriptionCacheStoring? = nil
    ) -> AppState {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmModel: "",
            llmVerifiedModel: "",
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
        appState.subscriptionCacheStore = cacheStore ?? InMemorySubscriptionCacheStore()
        return appState
    }

    private func status(
        plan: ManagedSubscription.Plan,
        statusValue: ManagedSubscription.Status
    ) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: plan, status: statusValue)
        )
    }

    private func managedQuota() -> ManagedQuota {
        ManagedQuota(
            used: 1,
            limit: 10,
            remaining: 9,
            resetsAt: Date().addingTimeInterval(86_400)
        )
    }

    func testUnknownActiveSubscriptionBlocksNewCheckout() {
        let scenarios: [(ManagedSubscription.Plan, ManagedSubscription.Status)] = [
            (.unknown, .active),
            (.pro, .unknown)
        ]

        for (plan, statusValue) in scenarios {
            let llm = StatusLLM()
            let appState = makeSignedInAppState(llm: llm)
            appState.managedAccountStatus = status(plan: plan, statusValue: statusValue)

            XCTAssertTrue(
                appState.hasManageablePaidSubscription,
                "plan \(plan.rawValue), status \(statusValue.rawValue) should be handled through billing management"
            )
            XCTAssertFalse(appState.shouldOfferSubscribe)

            appState.presentBillingCheckout()
            XCTAssertNil(appState.billingCheckout)
        }
    }

    func testManagedLicenseCachesQuotaOnlyAccountStatusForGrace() async {
        let llm = StatusLLM()
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: managedQuota()
        )
        let appState = makeSignedInAppState(llm: llm)

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.managedLicense, .entitled)
        XCTAssertTrue(appState.managedLicenseAllowsLLMRequests)
        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.source, .legacyQuota)
        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.status, .active)
        XCTAssertTrue(appState.shouldOfferSubscribe)

        appState.managedAccountStatusFreshUntil = Date().addingTimeInterval(-1)
        guard case .grace = appState.managedLicense else {
            return XCTFail("expected quota-only status to fall back to cached grace")
        }
    }

    func testQuotaOnlyAccountStatusPreservesPaidSubscriptionSnapshot() async {
        let llm = StatusLLM()
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: managedQuota()
        )
        let store = InMemorySubscriptionCacheStore()
        let appState = makeSignedInAppState(llm: llm, cacheStore: store)
        let accountKey = appState.currentManagedUsageAccountKey
        let paidSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .active,
            manageBillingURL: "https://billing.example.com/session",
            capturedAt: Date().addingTimeInterval(-8 * 86_400)
        )
        store.save(paidSnapshot, accountKey: accountKey)

        let refreshStartedAt = Date()
        await appState.refreshManagedQuota()

        guard let refreshedSnapshot = appState.cachedSubscriptionSnapshot else {
            return XCTFail("expected quota-only refresh to renew the paid snapshot")
        }
        XCTAssertEqual(refreshedSnapshot.plan, .pro)
        XCTAssertEqual(refreshedSnapshot.status, .active)
        XCTAssertEqual(refreshedSnapshot.source, .subscription)
        XCTAssertEqual(refreshedSnapshot.manageBillingURL, "https://billing.example.com/session")
        XCTAssertGreaterThanOrEqual(refreshedSnapshot.capturedAt, refreshStartedAt)
        XCTAssertEqual(store.saved[accountKey], refreshedSnapshot)
        XCTAssertFalse(appState.shouldOfferSubscribe)
        XCTAssertEqual(appState.manageBillingURL?.absoluteString, "https://billing.example.com/session")

        appState.isOnline = false
        appState.managedAccountStatus = nil
        guard case .grace = appState.managedLicense else {
            return XCTFail("expected refreshed quota-only success to allow offline grace")
        }
    }

    func testQuotaOnlyAccountStatusMigratesPaidSnapshotAcrossAccountKeyBackfill() async {
        let llm = StatusLLM()
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: managedQuota()
        )
        let store = InMemorySubscriptionCacheStore()
        let appState = makeSignedInAppState(llm: llm, cacheStore: store)
        appState.managedAccountID = "clerk-session:sess_X"
        let sessionKey = appState.currentManagedUsageAccountKey
        store.save(
            SubscriptionSnapshot(
                plan: .pro,
                status: .active,
                manageBillingURL: "https://billing.example.com/session",
                capturedAt: Date().addingTimeInterval(-8 * 86_400)
            ),
            accountKey: sessionKey
        )

        await appState.refreshManagedQuota()

        let stableKey = appState.currentManagedUsageAccountKey
        XCTAssertNotEqual(sessionKey, stableKey)
        XCTAssertEqual(appState.managedAccountID, "clerk-user:user_marcus")
        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.plan, .pro)
        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.status, .active)
        XCTAssertFalse(appState.shouldOfferSubscribe)
        XCTAssertEqual(appState.manageBillingURL?.absoluteString, "https://billing.example.com/session")
        XCTAssertEqual(store.saved[stableKey]?.plan, .pro)
        XCTAssertEqual(store.saved[stableKey]?.manageBillingURL, "https://billing.example.com/session")
    }

    func testQuotaOnlyAccountStatusUsesCompatibilityStatusForPastDueSnapshot() async {
        let llm = StatusLLM()
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: managedQuota()
        )
        let store = InMemorySubscriptionCacheStore()
        let appState = makeSignedInAppState(llm: llm, cacheStore: store)
        let accountKey = appState.currentManagedUsageAccountKey
        store.save(
            SubscriptionSnapshot(
                plan: .pro,
                status: .pastDue,
                manageBillingURL: "https://billing.example.com/session",
                capturedAt: Date().addingTimeInterval(-8 * 86_400)
            ),
            accountKey: accountKey
        )

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.plan, .pro)
        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.status, .active)
        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.source, .legacyQuota)
        XCTAssertFalse(appState.shouldOfferSubscribe)
        XCTAssertEqual(appState.manageBillingURL?.absoluteString, "https://billing.example.com/session")
        let model = SubscriptionPaneModel.make(
            from: appState.managedAccountStatus,
            snapshot: appState.effectiveSubscriptionSnapshot,
            statusIsFresh: appState.managedAccountStatusIsFresh
        )
        XCTAssertEqual(model.planText, "Pro")
        XCTAssertFalse(model.isProblemState)
    }

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        private(set) var saved: [String: SubscriptionSnapshot] = [:]
        func snapshot(accountKey: String) -> SubscriptionSnapshot? { saved[accountKey] }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) { saved[accountKey] = snapshot }
        func clear(accountKey: String) { saved[accountKey] = nil }
    }
}
