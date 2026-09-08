import XCTest
@testable import Sentwise

@MainActor
final class AppStateManagedStatusOrderingTests: XCTestCase {

    private final class DeferredStatusLLM: LLMProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var pendingFetches: [CheckedContinuation<ManagedAccountStatus?, Error>?] = []
        private var fetchCallCount = 0
        var planChange = PaddlePlanChange(plan: .pro, status: .active)

        var fetchCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return fetchCallCount
        }

        func testConnection(
            provider: LLMProviderKind,
            apiKey: String,
            model: String,
            baseURL: String?
        ) async throws {}

        func complete(
            _ request: LLMRequest,
            provider: LLMProviderKind,
            apiKey: String,
            baseURL: String?
        ) async throws -> LLMResponse {
            LLMResponse(text: "")
        }

        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                fetchCallCount += 1
                pendingFetches.append(continuation)
                lock.unlock()
            }
        }

        func fetchManagedQuota() async throws -> ManagedQuota? { nil }
        func deleteManagedAccount() async throws {}
        func changeManagedPlan(priceID: String, expectedAccountKey: String?) async throws -> PaddlePlanChange {
            planChange
        }

        func completeFetch(at index: Int, with result: Result<ManagedAccountStatus?, Error>) {
            lock.lock()
            let continuation = pendingFetches.indices.contains(index) ? pendingFetches[index] : nil
            if pendingFetches.indices.contains(index) {
                pendingFetches[index] = nil
            }
            lock.unlock()
            continuation?.resume(with: result)
        }
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

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000)
            await Task.yield()
        }
    }

    func testOverlappingRefreshKeepsLatestManagedAccountStatus() async {
        let llm = DeferredStatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }

        let firstRefresh = Task { await appState.refreshManagedQuota() }
        await waitUntil { llm.fetchCount == 1 }
        let secondRefresh = Task { await appState.refreshManagedQuota() }
        await waitUntil { llm.fetchCount == 2 }

        llm.completeFetch(at: 1, with: .success(status(plan: .pro, statusValue: .active)))
        await secondRefresh.value
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.plan, .pro)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.status, .active)
        XCTAssertEqual(appState.managedLicense, .entitled)

        llm.completeFetch(at: 0, with: .success(status(plan: .trial, statusValue: .trialing)))
        await firstRefresh.value

        XCTAssertEqual(appState.managedAccountStatus?.subscription?.plan, .pro)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.status, .active)
        XCTAssertEqual(appState.managedLicense, .entitled)
    }

    func testOlderSuccessfulRefreshIsAcceptedAfterNewerFailure() async {
        let llm = DeferredStatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }

        let firstRefresh = Task { await appState.refreshManagedQuota() }
        await waitUntil { llm.fetchCount == 1 }
        let secondRefresh = Task { await appState.refreshManagedQuota() }
        await waitUntil { llm.fetchCount == 2 }

        llm.completeFetch(at: 1, with: .failure(NSError(domain: "StatusOrdering", code: 1)))
        await secondRefresh.value
        XCTAssertFalse(appState.managedAccountStatusIsFresh)

        llm.completeFetch(at: 0, with: .success(status(plan: .pro, statusValue: .active)))
        await firstRefresh.value

        XCTAssertEqual(appState.managedAccountStatus?.subscription?.plan, .pro)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.status, .active)
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedLicense, .entitled)
    }

    func testNewerFailureDoesNotClearOverlappingSuccess() async {
        let llm = DeferredStatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }

        let firstRefresh = Task { await appState.refreshManagedQuota() }
        await waitUntil { llm.fetchCount == 1 }
        let secondRefresh = Task { await appState.refreshManagedQuota() }
        await waitUntil { llm.fetchCount == 2 }

        llm.completeFetch(at: 0, with: .success(status(plan: .pro, statusValue: .active)))
        await firstRefresh.value
        XCTAssertTrue(appState.managedAccountStatusIsFresh)

        llm.completeFetch(at: 1, with: .failure(NSError(domain: "StatusOrdering", code: 1)))
        await secondRefresh.value

        XCTAssertEqual(appState.managedAccountStatus?.subscription?.plan, .pro)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.status, .active)
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedLicense, .entitled)
    }

    func testManagedEntitlementErrorSupersedesInFlightStatusRefresh() async {
        let llm = DeferredStatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }
        let active = status(plan: .pro, statusValue: .active)
        appState.managedAccountStatus = active
        appState.markManagedAccountStatusFresh(from: active)
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(plan: .pro, status: .active, capturedAt: Date())

        let refresh = Task { await appState.refreshManagedQuota() }
        await waitUntil { llm.fetchCount == 1 }

        let changed = await appState.reconcileManagedAccountState(
            after: LLMError.managedTrialExpired("Payment required."),
            provider: .managed
        )
        XCTAssertTrue(changed)
        XCTAssertNil(appState.managedAccountStatus)
        XCTAssertEqual(appState.managedLicense, .notEntitled)

        llm.completeFetch(at: 0, with: .success(active))
        await refresh.value

        XCTAssertNil(appState.managedAccountStatus)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedLicense, .notEntitled)
    }

    func testPlanChangeFallbackSupersedesOlderInFlightStatusRefresh() async {
        let llm = DeferredStatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer {
            appState.cancelScheduledManagedAccountStatusRefresh()
            appState.cancelPlanChangeReconciliation()
        }
        let starter = status(plan: .starter, statusValue: .active)
        appState.managedAccountStatus = starter
        appState.markManagedAccountStatusFresh(from: starter)

        let oldRefresh = Task { await appState.refreshManagedQuota() }
        await waitUntil { llm.fetchCount == 1 }
        let change = Task {
            await appState.changePlan(to: .pro, reconcileRetryDelays: [], backgroundReconcileRetryDelays: [])
        }
        await waitUntil { llm.fetchCount == 2 }

        llm.completeFetch(at: 1, with: .failure(NSError(domain: "StatusOrdering", code: 1)))
        await change.value
        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)

        llm.completeFetch(at: 0, with: .success(starter))
        await oldRefresh.value

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
    }

    func testTargetTierRequiresSuccessfulStatusBeforePlanChangeConfirms() async {
        let llm = DeferredStatusLLM()
        llm.planChange = PaddlePlanChange(plan: .pro, status: .canceled)
        let appState = makeSignedInAppState(llm: llm)
        defer {
            appState.cancelScheduledManagedAccountStatusRefresh()
            appState.cancelPlanChangeReconciliation()
        }
        let starter = status(plan: .starter, statusValue: .active)
        appState.managedAccountStatus = starter
        appState.markManagedAccountStatusFresh(from: starter)
        let quota = ManagedQuota(used: 1, limit: 120, remaining: 119, resetsAt: Date(), tokenLimit: 1_200)
        let canceledTarget = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: quota,
            subscription: ManagedSubscription(plan: .pro, status: .canceled)
        )

        let change = Task {
            await appState.changePlan(
                to: .pro,
                reconcileRetryDelays: [],
                backgroundReconcileRetryDelays: []
            )
        }
        await waitUntil { llm.fetchCount == 1 }
        llm.completeFetch(at: 0, with: .success(canceledTarget))
        await change.value

        XCTAssertTrue(appState.planChangeFailed)
        XCTAssertEqual(appState.planChangeMessage, AppState.changePlanConfirmationPendingMessage())
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.status, .canceled)
    }

    func testTargetStatusCanConfirmPlanChangeWhenQuotaIsOmitted() async {
        let llm = DeferredStatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer {
            appState.cancelScheduledManagedAccountStatusRefresh()
            appState.cancelPlanChangeReconciliation()
        }
        let starter = status(plan: .starter, statusValue: .active)
        let target = status(plan: .pro, statusValue: .active)
        appState.managedAccountStatus = starter
        appState.markManagedAccountStatusFresh(from: starter)

        let change = Task {
            await appState.changePlan(
                to: .pro,
                reconcileRetryDelays: [],
                backgroundReconcileRetryDelays: [0]
            )
        }
        await waitUntil { llm.fetchCount == 1 }
        llm.completeFetch(at: 0, with: .success(target))
        await change.value
        if appState.planChangeReconciliationTask != nil {
            await waitUntil { llm.fetchCount == 2 }
            llm.completeFetch(at: 1, with: .success(target))
            await waitUntil { appState.planChangeReconciliationTask == nil }
        }

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertEqual(appState.planChangeMessage, AppState.changePlanConfirmation(for: .pro))
        XCTAssertFalse(appState.planChangeFailed)
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
    }

    func testPendingPlanChangeReconciliationDefersLaterOldTierRefresh() async {
        let llm = DeferredStatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer {
            appState.cancelScheduledManagedAccountStatusRefresh()
            appState.cancelPlanChangeReconciliation()
        }
        let starter = status(plan: .starter, statusValue: .active)
        appState.managedAccountStatus = starter
        appState.markManagedAccountStatusFresh(from: starter)

        let change = Task {
            await appState.changePlan(
                to: .pro,
                reconcileRetryDelays: [],
                backgroundReconcileRetryDelays: [1_000_000_000]
            )
        }
        await waitUntil { llm.fetchCount == 1 }
        llm.completeFetch(at: 0, with: .success(starter))
        await change.value

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertNotNil(appState.planChangeReconciliationTask)

        let laterRefresh = Task { await appState.refreshManagedQuota() }
        await waitUntil { llm.fetchCount == 2 }
        llm.completeFetch(at: 1, with: .success(starter))
        await laterRefresh.value

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertNotNil(appState.planChangeReconciliationTask)

        let quota = ManagedQuota(used: 2, limit: 120, remaining: 118, resetsAt: Date(), tokenLimit: 1_200)
        let target = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: quota,
            subscription: ManagedSubscription(plan: .pro, status: .active)
        )
        let confirmingRefresh = Task { await appState.refreshManagedQuota() }
        await waitUntil { llm.fetchCount == 3 }
        llm.completeFetch(at: 2, with: .success(target))
        await confirmingRefresh.value

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedQuota, quota)
        XCTAssertNil(appState.planChangeReconciliationTask)
    }

    func testPlanChangeBackgroundReconciliationAppliesOldTierWhenRetriesExpire() async {
        let llm = DeferredStatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer {
            appState.cancelScheduledManagedAccountStatusRefresh()
            appState.cancelPlanChangeReconciliation()
        }
        let starter = status(plan: .starter, statusValue: .active)
        appState.managedAccountStatus = starter
        appState.markManagedAccountStatusFresh(from: starter)

        let change = Task {
            await appState.changePlan(
                to: .pro,
                reconcileRetryDelays: [],
                backgroundReconcileRetryDelays: [0, 0]
            )
        }
        await waitUntil { llm.fetchCount == 1 }
        llm.completeFetch(at: 0, with: .success(starter))
        await change.value
        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)

        await waitUntil { llm.fetchCount == 2 }
        llm.completeFetch(at: 1, with: .success(starter))
        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)

        await waitUntil { llm.fetchCount == 3 }
        llm.completeFetch(at: 2, with: .success(starter))
        await waitUntil { appState.planChangeReconciliationTask == nil }

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .starter)
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertTrue(appState.planChangeFailed)
        XCTAssertEqual(appState.planChangeMessage, AppState.changePlanConfirmationPendingMessage())
    }

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        private(set) var saved: [String: SubscriptionSnapshot] = [:]

        func snapshot(accountKey: String) -> SubscriptionSnapshot? { saved[accountKey] }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) { saved[accountKey] = snapshot }
        func clear(accountKey: String) { saved[accountKey] = nil }
    }
}
