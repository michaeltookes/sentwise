import XCTest
@testable import Sentwise

@MainActor
final class AppStateManagedTrialRetryTests: XCTestCase {

    private final class StatusLLM: LLMProviding, @unchecked Sendable {
        var statusToReturn: ManagedAccountStatus?
        var statusesToReturn: [ManagedAccountStatus?] = []
        private(set) var fetchCount = 0

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
            LLMResponse(text: "")
        }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
            fetchCount += 1
            if !statusesToReturn.isEmpty {
                return statusesToReturn.removeFirst()
            }
            return statusToReturn
        }
        func fetchManagedQuota() async throws -> ManagedQuota? { statusToReturn?.quota }
        func deleteManagedAccount() async throws {}
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
        appState.subscriptionCacheStore = InMemorySubscriptionCacheStore()
        return appState
    }

    private func quota(limit: Int, remaining: Int, extraPurchased: Int = 0) -> ManagedQuota {
        ManagedQuota(
            used: limit - remaining,
            limit: limit,
            remaining: remaining,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            extraPurchased: extraPurchased
        )
    }

    func testExpiredTrialStatusSchedulesBoundedRetryInsteadOfImmediateLoop() async throws {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            trial: ManagedTrial(endsAt: Date().addingTimeInterval(-1), active: true),
            subscription: ManagedSubscription(plan: .trial, status: .trialing)
        )

        await appState.refreshManagedQuota()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertNil(appState.managedAccountStatusFreshUntil)
    }

    func testTrialFreshnessDeadlineFallsBackToSubscriptionRenewalDate() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        let renewsAt = Date().addingTimeInterval(300)
        let trialing = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .trial, status: .trialing, renewsAt: renewsAt)
        )

        appState.markManagedAccountStatusFresh(from: trialing)

        XCTAssertEqual(
            appState.managedAccountStatusFreshUntil?.timeIntervalSince1970 ?? 0,
            renewsAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testBillingPortalReturnRefreshesManagedStatus() async {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        let portalURL = "https://billing.example/portal"
        let pastDue = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .pastDue, manageBillingURL: portalURL)
        )
        appState.managedAccountStatus = pastDue
        appState.markManagedAccountStatusFresh(from: pastDue)
        var openedURL: URL?
        llm.statusToReturn = pastDue

        await appState.openManageBilling { openedURL = $0 }

        XCTAssertEqual(openedURL?.absoluteString, portalURL)
        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertTrue(appState.billingPortalRefreshPending)

        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active, manageBillingURL: portalURL)
        )
        await appState.refreshManagedQuotaAfterBillingPortalReturnIfNeeded()

        XCTAssertEqual(llm.fetchCount, 2)
        XCTAssertFalse(appState.billingPortalRefreshPending)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.status, .active)
        XCTAssertEqual(appState.managedLicense, .entitled)
    }

    func testBillingPortalReturnReconcilesAfterInitialPastDueRefresh() async throws {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelBillingReconciliation() }
        let portalURL = "https://billing.example/portal"
        let pastDue = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .pastDue, manageBillingURL: portalURL)
        )
        appState.managedAccountStatus = pastDue
        appState.markManagedAccountStatusFresh(from: pastDue)
        llm.statusToReturn = pastDue
        await appState.openManageBilling { _ in }
        llm.statusesToReturn = [
            pastDue,
            ManagedAccountStatus(
                userID: "user_marcus",
                email: "marcus@example.com",
                subscription: ManagedSubscription(plan: .pro, status: .active, manageBillingURL: portalURL)
            )
        ]

        await appState.refreshManagedQuotaAfterBillingPortalReturnIfNeeded(reconciliationRetryDelays: [0])
        for _ in 0..<1_000 where llm.fetchCount < 3 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(llm.fetchCount, 3)
        XCTAssertFalse(appState.billingPortalRefreshPending)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.status, .active)
        XCTAssertEqual(appState.managedLicense, .entitled)
        XCTAssertNil(appState.billingReconciliationTask)
    }

    func testBillingPortalReturnReconcilesActivePlanUntilSubscriptionOrQuotaChanges() async throws {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelBillingReconciliation() }
        let portalURL = "https://billing.example/portal"
        let oldStatus = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: quota(limit: 50, remaining: 25),
            subscription: ManagedSubscription(plan: .pro, status: .active, manageBillingURL: portalURL)
        )
        let upgradedStatus = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: quota(limit: 100, remaining: 75, extraPurchased: 50),
            subscription: ManagedSubscription(plan: .unlimited, status: .active, manageBillingURL: portalURL)
        )
        let usageDriftStatus = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: quota(limit: 50, remaining: 20),
            subscription: ManagedSubscription(plan: .pro, status: .active, manageBillingURL: "https://billing.example/new-session")
        )
        appState.managedAccountStatus = oldStatus
        appState.managedQuota = oldStatus.quota
        appState.markManagedAccountStatusFresh(from: oldStatus)
        llm.statusToReturn = oldStatus
        await appState.openManageBilling { _ in }
        llm.statusesToReturn = [usageDriftStatus, upgradedStatus]

        await appState.refreshManagedQuotaAfterBillingPortalReturnIfNeeded(reconciliationRetryDelays: [0])
        for _ in 0..<1_000 where llm.fetchCount < 3 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(llm.fetchCount, 3)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.plan, .unlimited)
        XCTAssertEqual(appState.managedQuota?.limit, 100)
        XCTAssertNil(appState.billingReconciliationTask)
    }

    func testInitialWatchStartRefreshesAndResumesAfterStaleNotEntitledLicenseRecovery() async {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .pastDue,
            capturedAt: Date()
        )
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "app-pw"
        appState.isAccountConnected = true
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active)
        )

        XCTAssertEqual(appState.managedLicense, .notEntitled)
        XCTAssertFalse(appState.canWatch)
        appState.startWatchingIfReady()

        for _ in 0..<1_000 where appState.watchStatus != .watching {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertGreaterThanOrEqual(llm.fetchCount, 1)
        XCTAssertEqual(appState.watchStatus, .watching)
        XCTAssertFalse(appState.resumeWatchingAfterManagedReauth)
        appState.stopWatching()
    }

    func testManagedEntitlementErrorInvalidatesCachedActiveStateAndPreservesWatcherIntent() async {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }
        let portalURL = "https://billing.example/portal"
        let active = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active, manageBillingURL: portalURL)
        )
        appState.managedAccountStatus = active
        appState.markManagedAccountStatusFresh(from: active)
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .active,
            manageBillingURL: portalURL,
            capturedAt: Date()
        )
        appState.watchStatus = .watching
        let error = LLMError.managedTrialExpired("Payment required.")

        let stateChanged = await appState.reconcileManagedAccountState(after: error, provider: .managed)
        appState.handleWatcherDraftError(error, draftProvider: .managed)

        XCTAssertTrue(stateChanged)
        XCTAssertNil(appState.managedAccountStatus)
        XCTAssertEqual(appState.managedLicense, .notEntitled)
        XCTAssertTrue(appState.canManageBilling)
        XCTAssertFalse(appState.shouldOfferSubscribe)
        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.status, .pastDue)
        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.manageBillingURL, portalURL)
        XCTAssertEqual(
            appState.subscriptionCacheStore.snapshot(accountKey: appState.currentManagedUsageAccountKey)?.status,
            .pastDue
        )
        XCTAssertEqual(appState.watchStatus, .paused)
        XCTAssertTrue(appState.resumeWatchingAfterManagedReauth)
        XCTAssertNotNil(appState.managedAccountStatusRefreshTask)
    }

    func testBlockingSubscriptionStatusUsesShortFreshnessWindow() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        let now = Date()
        let pastDue = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .pastDue)
        )

        appState.markManagedAccountStatusFresh(from: pastDue, now: now)

        XCTAssertEqual(
            appState.managedAccountStatusFreshUntil?.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(300).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testFreshPastDueRefreshKeepsWatcherResumeIntent() async {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.watchStatus = .paused
        appState.resumeWatchingAfterManagedReauth = true
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .pastDue)
        )

        await appState.refreshManagedQuota()

        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedLicense, .notEntitled)
        XCTAssertTrue(appState.resumeWatchingAfterManagedReauth)
    }

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        private var snapshots: [String: SubscriptionSnapshot] = [:]

        func snapshot(accountKey: String) -> SubscriptionSnapshot? { snapshots[accountKey] }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) { snapshots[accountKey] = snapshot }
        func clear(accountKey: String) { snapshots.removeValue(forKey: accountKey) }
    }
}
