import XCTest
@testable import Sentwise

@MainActor
final class AppStateBillingPortalTests: XCTestCase {
    private final class StatusLLM: LLMProviding, @unchecked Sendable {
        var statusToReturn: ManagedAccountStatus?
        private(set) var fetchCount = 0

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws
            -> LLMResponse {
            LLMResponse(text: "")
        }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
            fetchCount += 1
            return statusToReturn
        }
        func fetchManagedQuota() async throws -> ManagedQuota? { statusToReturn?.quota }
        func deleteManagedAccount() async throws {}
    }

    func testOpenManageBillingFetchesFreshPortalURLInsteadOfCachedSnapshot() async {
        let llm = StatusLLM()
        llm.statusToReturn = status(plan: .pro, statusValue: .pastDue, billingURL: "https://billing.example/fresh")
        let appState = makeSignedInAppState(llm: llm)
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .pastDue,
            manageBillingURL: "https://billing.example/stale",
            capturedAt: Date().addingTimeInterval(-3 * 86_400)
        )
        var openedURL: URL?

        XCTAssertTrue(appState.canManageBilling)
        XCTAssertNil(appState.manageBillingURL)

        await appState.openManageBilling { openedURL = $0 }

        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertEqual(openedURL?.absoluteString, "https://billing.example/fresh")
        XCTAssertTrue(appState.billingPortalRefreshPending)
    }

    func testOpenManageBillingDoesNotOpenStaleLiveURLWhenRefreshReturnsNoStatus() async {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        let staleStatus = status(plan: .pro, statusValue: .pastDue, billingURL: "https://billing.example/stale")
        appState.managedAccountStatus = staleStatus
        appState.markManagedAccountStatusFresh(from: staleStatus)
        var openedURL: URL?

        XCTAssertTrue(appState.canManageBilling)

        await appState.openManageBilling { openedURL = $0 }

        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertNil(openedURL)
        XCTAssertFalse(appState.billingPortalRefreshPending)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
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
        billingURL: String
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
