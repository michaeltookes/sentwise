import XCTest
@testable import Sentwise

private enum StatusRefreshResult {
    case status(ManagedAccountStatus?)
    case failure
}

private actor StatusRefreshLLMProvider: LLMProviding {
    private var results: [StatusRefreshResult]
    private var statusFetchCount = 0

    init(results: [StatusRefreshResult]) {
        self.results = results
    }

    func fetchCount() -> Int {
        statusFetchCount
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
        statusFetchCount += 1
        let next = results.isEmpty ? .failure : results.removeFirst()
        switch next {
        case .status(let status):
            return status
        case .failure:
            throw NSError(domain: "AppStateManagedStatusRefreshRetryTests", code: 1)
        }
    }
}

@MainActor
final class AppStateManagedStatusRefreshRetryTests: XCTestCase {

    func testRefreshFailureSchedulesBoundedRetryTask() async {
        let llm = StatusRefreshLLMProvider(results: [.failure])
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }

        await appState.refreshManagedQuota()

        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertNotNil(appState.managedAccountStatusRefreshTask)
        let fetchCount = await llm.fetchCount()
        XCTAssertEqual(fetchCount, 1)
    }

    func testManagedStatusRefreshRetryStopsAfterSuccess() async throws {
        let llm = StatusRefreshLLMProvider(results: [.status(activeStatus())])
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }

        appState.scheduleManagedAccountStatusRefreshRetryAfterFailure(delays: [0])
        try await waitUntil {
            let fetchCount = await llm.fetchCount()
            return fetchCount >= 1
        }

        let fetchCount = await llm.fetchCount()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedLicense, .entitled)
    }

    func testQuotaLessStatusRefreshKeepsStatusStaleAndSchedulesRetry() async {
        let staleQuota = managedQuota(limit: 10)
        let llm = StatusRefreshLLMProvider(results: [.status(activeStatus(quota: nil))])
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }
        appState.managedQuota = staleQuota
        appState.pendingPlanChangeReconciliation = PendingPlanChangeReconciliation(
            tier: .pro,
            accountKey: appState.currentManagedUsageAccountKey,
            generation: appState.planChangeReconciliationGeneration
        )

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertEqual(appState.managedQuota, staleQuota)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertNotNil(appState.managedAccountStatusRefreshTask)
    }

    func testStatusRetryClearsPendingPlanConfirmationErrorWhenTargetAppears() async {
        let llm = StatusRefreshLLMProvider(results: [.status(activeStatus())])
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }
        appState.planChangeFailed = true
        appState.planChangeMessage = AppState.changePlanConfirmationPendingMessage()
        appState.pendingPlanChangeReconciliation = PendingPlanChangeReconciliation(
            tier: .pro,
            accountKey: appState.currentManagedUsageAccountKey,
            generation: appState.planChangeReconciliationGeneration
        )

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertFalse(appState.planChangeFailed)
        XCTAssertEqual(appState.planChangeMessage, AppState.changePlanConfirmation(for: .pro))
        XCTAssertNil(appState.pendingPlanChangeReconciliation)
    }

    func testManagedStatusRefreshRetryStopsAfterBoundedFailures() async throws {
        let llm = StatusRefreshLLMProvider(results: [.failure, .failure])
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }

        appState.scheduleManagedAccountStatusRefreshRetryAfterFailure(delays: [0, 0])
        try await waitUntil {
            let fetchCount = await llm.fetchCount()
            return fetchCount >= 2 && appState.managedAccountStatusRefreshTask == nil
        }

        let fetchCount = await llm.fetchCount()
        XCTAssertEqual(fetchCount, 2)
        XCTAssertNil(appState.managedAccountStatusRefreshTask)
    }

    private func makeSignedInAppState(llm: LLMProviding) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                llmProvider: "managed",
                llmModel: "",
                llmVerifiedModel: "",
                managedAccountEmail: "marcus@example.com",
                managedAccountID: "clerk-user:user_marcus"
            )),
            secrets: InMemorySecretStore(seed: [
                .managedClientToken: "client_X",
                .managedSessionID: "sess_X"
            ]),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm
        )
    }

    private func activeStatus() -> ManagedAccountStatus {
        activeStatus(quota: managedQuota(limit: 120))
    }

    private func activeStatus(quota: ManagedQuota?) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: quota,
            subscription: ManagedSubscription(plan: .pro, status: .active)
        )
    }

    private func managedQuota(limit: Int) -> ManagedQuota {
        ManagedQuota(
            used: 1,
            limit: limit,
            remaining: max(limit - 1, 0),
            resetsAt: Date(),
            tokenLimit: limit * 10
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 100,
        condition: () async -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
