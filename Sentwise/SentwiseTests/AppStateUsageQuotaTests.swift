import XCTest
@testable import Sentwise

/// In-memory usage-alert state store for AppState metering tests (item 56b).
private final class InMemoryUsageAlertStore: UsageAlertStateStoring, @unchecked Sendable {
    var state: UsageAlertState?
    func loadState() -> UsageAlertState? { state }
    func save(_ state: UsageAlertState) { self.state = state }
}

/// An `LLMProviding` double whose `/v1/me` fetch returns a fixed quota (item 56b).
private final class QuotaLLMProvider: LLMProviding, @unchecked Sendable {
    var quota: ManagedQuota?
    private(set) var fetchCount = 0
    init(quota: ManagedQuota?) { self.quota = quota }
    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
    func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
        LLMResponse(text: "")
    }
    func fetchManagedQuota() async throws -> ManagedQuota? {
        fetchCount += 1
        return quota
    }
}

/// AppState-level metering behavior (item 56b): mirroring quota into published
/// state, once-per-window alert firing, window reset, and the `/v1/me` refresh.
@MainActor
final class AppStateUsageQuotaTests: XCTestCase {

    private let window = ManagedQuotaDate.date(from: "2025-09-01T00:00:00Z")!
    private let nextWindow = ManagedQuotaDate.date(from: "2025-09-08T00:00:00Z")!

    private func quota(used: Int, limit: Int = 100, enforcement: ManagedQuota.Enforcement = .soft, resetsAt: Date? = nil) -> ManagedQuota {
        ManagedQuota(
            unit: "drafts",
            used: used,
            limit: limit,
            remaining: max(0, limit - used),
            resetsAt: resetsAt ?? window,
            enforcement: enforcement
        )
    }

    private func makeAppState(
        notifier: FakeDraftNotifier = FakeDraftNotifier(),
        store: UsageAlertStateStoring = InMemoryUsageAlertStore(),
        llm: LLMProviding = FakeLLMProvider(result: .success(())),
        secrets: SecretStore = InMemorySecretStore(),
        persistence: AppStateMemoryPersistence = AppStateMemoryPersistence()
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: notifier,
            usageAlertStore: store
        )
    }

    private func signedInFixture() -> (secrets: SecretStore, persistence: AppStateMemoryPersistence) {
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
            managedAccountEmail: "marcus@example.com"
        ))
        return (secrets, persistence)
    }

    // MARK: - Ingest

    func testIngestUpdatesPublishedQuota() {
        let appState = makeAppState()
        let q = quota(used: 12, limit: 50)
        appState.ingestManagedQuota(q)
        XCTAssertEqual(appState.managedQuota, q)
    }

    func testIngestFiresThresholdAlertOncePerWindow() {
        let notifier = FakeDraftNotifier()
        let store = InMemoryUsageAlertStore()
        let appState = makeAppState(notifier: notifier, store: store)

        appState.ingestManagedQuota(quota(used: 55))
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.fifty])

        // A later report in the same window, still between 50–75%, fires nothing.
        appState.ingestManagedQuota(quota(used: 60))
        XCTAssertEqual(notifier.usageAlerts.count, 1)

        // Crossing 75% fires only the new threshold.
        appState.ingestManagedQuota(quota(used: 80))
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.fifty, .seventyFive])
    }

    func testIngestResetsAlertsOnNewWindow() {
        let notifier = FakeDraftNotifier()
        let appState = makeAppState(notifier: notifier)

        appState.ingestManagedQuota(quota(used: 100))
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.fifty, .seventyFive, .hundred])

        // New week, back to 55% — 50% fires again in the fresh window.
        appState.ingestManagedQuota(quota(used: 55, resetsAt: nextWindow))
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.fifty, .seventyFive, .hundred, .fifty])
    }

    func testIngestPersistsFiredStateSoRelaunchDoesNotRefire() {
        let store = InMemoryUsageAlertStore()
        let firstNotifier = FakeDraftNotifier()
        let first = makeAppState(notifier: firstNotifier, store: store)
        first.ingestManagedQuota(quota(used: 55))
        XCTAssertEqual(firstNotifier.usageAlerts.count, 1)

        // Simulate a relaunch: a fresh AppState sharing the persisted store.
        let secondNotifier = FakeDraftNotifier()
        let second = makeAppState(notifier: secondNotifier, store: store)
        second.ingestManagedQuota(quota(used: 60))
        XCTAssertTrue(secondNotifier.usageAlerts.isEmpty, "a relaunch must not re-fire an already-fired threshold")
    }

    // MARK: - Refresh

    func testRefreshManagedQuotaFetchesAndIngestsWhenSignedIn() async {
        let fixture = signedInFixture()
        let notifier = FakeDraftNotifier()
        let llm = QuotaLLMProvider(quota: quota(used: 50))
        let appState = makeAppState(
            notifier: notifier,
            llm: llm,
            secrets: fixture.secrets,
            persistence: fixture.persistence
        )
        XCTAssertTrue(appState.isManagedSignedIn)

        await appState.refreshManagedQuota()

        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertEqual(appState.managedQuota?.used, 50)
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.fifty])
    }

    func testRefreshSkipsWhenNotSignedIn() async {
        let llm = QuotaLLMProvider(quota: quota(used: 50))
        let appState = makeAppState(llm: llm) // fresh install: managed but signed out
        XCTAssertFalse(appState.isManagedSignedIn)

        await appState.refreshManagedQuota()

        XCTAssertEqual(llm.fetchCount, 0, "no /v1/me fetch when not signed in")
        XCTAssertNil(appState.managedQuota)
    }

    func testIsManagedQuotaExhausted() {
        let appState = makeAppState()
        XCTAssertFalse(appState.isManagedQuotaExhausted)
        appState.ingestManagedQuota(quota(used: 100))
        XCTAssertTrue(appState.isManagedQuotaExhausted)
    }
}
