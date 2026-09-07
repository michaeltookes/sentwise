import XCTest
@testable import Sentwise

@MainActor
final class AppStateQuotaMetadataOrderingTests: XCTestCase {

    private let window = ManagedQuotaDate.date(from: "2025-09-01T00:00:00Z")!

    private final class QuotaLLMProvider: LLMProviding, @unchecked Sendable {
        var status: ManagedAccountStatus?

        init(quota: ManagedQuota?) {
            status = ManagedAccountStatus(quota: quota)
        }

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
            LLMResponse(text: "")
        }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? { status }
        func fetchManagedQuota() async throws -> ManagedQuota? { status?.quota }
    }

    func testDraftQuotaReportDoesNotDowngradeCapacityMetadataAfterStatusRefresh() async {
        let notifier = FakeDraftNotifier()
        let upgraded = quota(used: 25, limit: 100, tokenLimit: 10_000, enforcement: .hard, extraPurchased: 50)
        let llm = QuotaLLMProvider(quota: upgraded)
        let appState = makeSignedInAppState(notifier: notifier, llm: llm)

        await appState.refreshManagedQuota()
        appState.ingestManagedQuota(quota(used: 26, limit: 50, tokenLimit: 5_000, extraPurchased: 0))

        XCTAssertEqual(appState.managedQuota?.used, 25)
        XCTAssertEqual(appState.managedQuota?.limit, 100)
        XCTAssertEqual(appState.managedQuota?.tokenLimit, 10_000)
        XCTAssertEqual(appState.managedQuota?.enforcement, .hard)
        XCTAssertEqual(appState.managedQuota?.extraPurchased, 50)
        XCTAssertTrue(notifier.usageAlerts.isEmpty)
    }

    func testDraftQuotaReportDoesNotUpgradeCapacityMetadataAfterStatusRefreshReduction() async {
        let notifier = FakeDraftNotifier()
        let reduced = quota(used: 25, limit: 50, tokenLimit: 5_000, enforcement: .soft, extraPurchased: 0)
        let llm = QuotaLLMProvider(quota: reduced)
        let appState = makeSignedInAppState(notifier: notifier, llm: llm)

        await appState.refreshManagedQuota()
        appState.ingestManagedQuota(quota(used: 26, limit: 100, tokenLimit: 10_000, enforcement: .hard, extraPurchased: 50))

        XCTAssertEqual(appState.managedQuota?.used, 25)
        XCTAssertEqual(appState.managedQuota?.limit, 50)
        XCTAssertEqual(appState.managedQuota?.tokenLimit, 5_000)
        XCTAssertEqual(appState.managedQuota?.enforcement, .soft)
        XCTAssertEqual(appState.managedQuota?.extraPurchased, 0)
        XCTAssertTrue(notifier.usageAlerts.isEmpty)
    }

    private func quota(
        used: Int,
        limit: Int,
        tokenLimit: Int = 0,
        enforcement: ManagedQuota.Enforcement = .soft,
        extraPurchased: Int = 0
    ) -> ManagedQuota {
        ManagedQuota(
            unit: "drafts",
            used: used,
            limit: limit,
            remaining: max(0, limit - used),
            resetsAt: window,
            tokenLimit: tokenLimit,
            enforcement: enforcement,
            extraPurchased: extraPurchased
        )
    }

    private func makeSignedInAppState(
        notifier: FakeDraftNotifier,
        llm: LLMProviding
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
            managedAccountID: "clerk-user:marcus@example.com"
        ))
        return AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: notifier
        )
    }
}
