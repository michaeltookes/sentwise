import XCTest
@testable import Sentwise

@MainActor
final class AppStateManagedTrialRetryTests: XCTestCase {

    private final class StatusLLM: LLMProviding, @unchecked Sendable {
        var statusToReturn: ManagedAccountStatus?
        private(set) var fetchCount = 0

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
            LLMResponse(text: "")
        }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
            fetchCount += 1
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

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        func snapshot(accountKey: String) -> SubscriptionSnapshot? { nil }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) {}
        func clear(accountKey: String) {}
    }
}
