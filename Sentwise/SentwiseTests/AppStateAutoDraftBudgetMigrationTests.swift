import XCTest
@testable import Sentwise

private final class AutoDraftBudgetMigrationLLMProvider: LLMProviding, @unchecked Sendable {
    private let status: ManagedAccountStatus?

    init(status: ManagedAccountStatus?) {
        self.status = status
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

    func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws
        -> LLMResponse {
        LLMResponse(text: "")
    }

    func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
        status
    }
}

@MainActor
final class AppStateAutoDraftBudgetMigrationTests: XCTestCase {
    private let window = ManagedQuotaDate.date(from: "2025-09-01T00:00:00Z")!

    func testRefreshManagedQuotaBackfillsStableAccountIDAndMigratesAutoDraftBudgetState() async {
        let oldAccountKey = ManagedUsageAccountKey.make(from: "clerk-session:sess_legacy")
        let budgetStore = InMemoryAutoDraftBudgetStore()
        budgetStore.save(AutoDraftBudgetState(
            accountKey: oldAccountKey,
            windowResetsAt: window,
            used: 1,
            capAlertFired: true
        ))
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_legacy"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            managedAccountEmail: "your Google account"
        ))
        let llm = AutoDraftBudgetMigrationLLMProvider(status: ManagedAccountStatus(
            userID: "user_123",
            quota: ManagedQuota(unit: "drafts", used: 20, limit: 100, remaining: 80, resetsAt: window)
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: FakeDraftNotifier()
        )
        appState.autoDraftBudgetStore = budgetStore
        appState.inboxDrafting.monthlyAutoDraftBudget = 1

        await appState.refreshManagedQuota()

        let newAccountKey = ManagedUsageAccountKey.make(from: "clerk-user:user_123")
        XCTAssertEqual(appState.managedAccountID, "clerk-user:user_123")
        XCTAssertNil(budgetStore.loadState(for: oldAccountKey))
        XCTAssertEqual(budgetStore.loadState(for: newAccountKey), AutoDraftBudgetState(
            accountKey: newAccountKey,
            windowResetsAt: window,
            used: 1,
            capAlertFired: true
        ))
        XCTAssertEqual(appState.autoDraftUsedThisWindow, 1)
        XCTAssertTrue(appState.isAutoDraftBudgetExhausted)
        XCTAssertFalse(appState.reserveAutoDraftBudgetUsageIfAvailable())
    }
}
