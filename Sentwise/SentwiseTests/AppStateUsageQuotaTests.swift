import XCTest
@testable import Sentwise

/// In-memory usage-alert state store for AppState metering tests (item 56b).
private final class InMemoryUsageAlertStore: UsageAlertStateStoring, @unchecked Sendable {
    var statesByAccount: [String: UsageAlertState] = [:]
    func loadState(for accountKey: String) -> UsageAlertState? { statesByAccount[accountKey] }
    func save(_ state: UsageAlertState) { statesByAccount[state.accountKey] = state }
}

/// An `LLMProviding` double whose `/v1/me` fetch returns a fixed quota (item 56b).
private final class QuotaLLMProvider: LLMProviding, @unchecked Sendable {
    var status: ManagedAccountStatus?
    var quota: ManagedQuota? {
        get { status?.quota }
        set { status = ManagedAccountStatus(userID: status?.userID, quota: newValue) }
    }
    private(set) var fetchCount = 0
    init(quota: ManagedQuota?) {
        self.status = ManagedAccountStatus(quota: quota)
    }
    init(status: ManagedAccountStatus?) {
        self.status = status
    }
    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
    func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
        LLMResponse(text: "")
    }
    func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
        fetchCount += 1
        return status
    }
    func fetchManagedQuota() async throws -> ManagedQuota? {
        fetchCount += 1
        return status?.quota
    }
}

/// An `LLMProviding` double that pauses `/v1/me` until the test resumes it,
/// letting AppState mutate account state while a quota refresh is in flight.
private final class BlockingQuotaLLMProvider: LLMProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ManagedQuota?, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var count = 0
    private var didStartFetch = false

    var fetchCount: Int { lock.withLock { count } }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
    func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
        LLMResponse(text: "")
    }

    func fetchManagedQuota() async throws -> ManagedQuota? {
        let pendingWaiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            count += 1
            didStartFetch = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pendingWaiters.forEach { $0.resume() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func waitUntilFetchStarted() async {
        if lock.withLock({ didStartFetch }) { return }
        await withCheckedContinuation { continuation in
            let shouldResumeNow = lock.withLock {
                guard !didStartFetch else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }

    func completeFetch(with quota: ManagedQuota?) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: quota)
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
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: notifier
        )
        appState.usageAlertStore = store
        return appState
    }

    private func signedInFixture(
        email: String = "marcus@example.com",
        provider: String = "managed",
        accountID: String? = nil
    ) -> (secrets: SecretStore, persistence: AppStateMemoryPersistence) {
        let resolvedAccountID = accountID ?? "clerk-user:\(email.lowercased())"
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: provider,
            llmModel: "",
            llmVerifiedModel: "",
            managedAccountEmail: email,
            managedAccountID: resolvedAccountID
        ))
        return (secrets, persistence)
    }

    private func makeSignedInAppState(
        email: String = "marcus@example.com",
        provider: String = "managed",
        accountID: String? = nil,
        notifier: FakeDraftNotifier = FakeDraftNotifier(),
        store: UsageAlertStateStoring = InMemoryUsageAlertStore(),
        llm: LLMProviding = FakeLLMProvider(result: .success(()))
    ) -> AppState {
        let fixture = signedInFixture(email: email, provider: provider, accountID: accountID)
        return makeAppState(
            notifier: notifier,
            store: store,
            llm: llm,
            secrets: fixture.secrets,
            persistence: fixture.persistence
        )
    }

    // MARK: - Ingest

    func testIngestUpdatesPublishedQuota() {
        let appState = makeSignedInAppState()
        let value = quota(used: 12, limit: 50)
        appState.ingestManagedQuota(value)
        XCTAssertEqual(appState.managedQuota, value)
        XCTAssertEqual(appState.managedQuotaAccountKey, ManagedUsageAccountKey.make(from: "clerk-user:marcus@example.com"))
    }

    func testUsageAccountKeyFallsBackToStoredClerkSessionID() {
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
        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertEqual(appState.currentManagedUsageAccountKey, ManagedUsageAccountKey.make(from: "clerk-session:sess_legacy"))
    }

    func testIngestFiresThresholdAlertOncePerWindow() {
        let notifier = FakeDraftNotifier()
        let store = InMemoryUsageAlertStore()
        let appState = makeSignedInAppState(notifier: notifier, store: store)

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
        let appState = makeSignedInAppState(notifier: notifier)

        appState.ingestManagedQuota(quota(used: 100))
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.fifty, .seventyFive, .hundred])

        // New week, back to 55% — 50% fires again in the fresh window.
        appState.ingestManagedQuota(quota(used: 55, resetsAt: nextWindow))
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.fifty, .seventyFive, .hundred, .fifty])
    }

    func testIngestPersistsFiredStateSoRelaunchDoesNotRefire() {
        let store = InMemoryUsageAlertStore()
        let firstNotifier = FakeDraftNotifier()
        let first = makeSignedInAppState(notifier: firstNotifier, store: store)
        first.ingestManagedQuota(quota(used: 55))
        XCTAssertEqual(firstNotifier.usageAlerts.count, 1)

        // Simulate a relaunch: a fresh AppState sharing the persisted store.
        let secondNotifier = FakeDraftNotifier()
        let second = makeSignedInAppState(notifier: secondNotifier, store: store)
        second.ingestManagedQuota(quota(used: 60))
        XCTAssertTrue(secondNotifier.usageAlerts.isEmpty, "a relaunch must not re-fire an already-fired threshold")
    }

    func testIngestKeepsAlertStateSeparateByManagedAccount() {
        let store = InMemoryUsageAlertStore()
        let firstNotifier = FakeDraftNotifier()
        let first = makeSignedInAppState(email: "marcus@example.com", notifier: firstNotifier, store: store)
        first.ingestManagedQuota(quota(used: 55))
        XCTAssertEqual(firstNotifier.usageAlerts.map(\.threshold), [.fifty])

        let secondNotifier = FakeDraftNotifier()
        let second = makeSignedInAppState(email: "priya@example.com", notifier: secondNotifier, store: store)
        second.ingestManagedQuota(quota(used: 60))
        XCTAssertEqual(secondNotifier.usageAlerts.map(\.threshold), [.fifty])

        let thirdNotifier = FakeDraftNotifier()
        let third = makeSignedInAppState(email: "marcus@example.com", notifier: thirdNotifier, store: store)
        third.ingestManagedQuota(quota(used: 60))
        XCTAssertTrue(thirdNotifier.usageAlerts.isEmpty, "switching back must preserve account A's fired thresholds")
    }

    func testDraftQuotaReportForOldAccountIsIgnoredAfterAccountSwitch() async throws {
        let notifier = FakeDraftNotifier()
        let appState = makeSignedInAppState(email: "marcus@example.com", notifier: notifier)
        let currentAccountKey = await appState.managedQuotaRelay.currentQuotaReportAccountKey()
        let oldAccountKey = try XCTUnwrap(currentAccountKey)

        appState.managedAccountEmail = "priya@example.com"
        appState.managedAccountID = "clerk-user:priya@example.com"
        appState.ingestManagedQuota(quota(used: 20))
        await appState.managedQuotaRelay.reportQuota(quota(used: 75), accountKey: oldAccountKey)

        XCTAssertEqual(appState.managedQuota?.used, 20)
        XCTAssertEqual(appState.managedQuotaAccountKey, ManagedUsageAccountKey.make(from: "clerk-user:priya@example.com"))
        XCTAssertTrue(notifier.usageAlerts.isEmpty)
    }

    func testIngestRejectsOlderQuotaWindowForSameAccount() {
        let notifier = FakeDraftNotifier()
        let appState = makeSignedInAppState(notifier: notifier)

        appState.ingestManagedQuota(quota(used: 10, resetsAt: nextWindow))
        appState.ingestManagedQuota(quota(used: 90, resetsAt: window))

        XCTAssertEqual(appState.managedQuota?.used, 10)
        XCTAssertEqual(appState.managedQuota?.resetsAt, nextWindow)
        XCTAssertTrue(notifier.usageAlerts.isEmpty)
    }

    func testIngestRejectsLowerUsageSnapshotInSameWindow() {
        let notifier = FakeDraftNotifier()
        let appState = makeSignedInAppState(notifier: notifier)

        appState.ingestManagedQuota(quota(used: 80))
        appState.ingestManagedQuota(quota(used: 55))

        XCTAssertEqual(appState.managedQuota?.used, 80)
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.fifty, .seventyFive])
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

    func testRefreshManagedQuotaFetchesWhenSignedInButBYOProviderActive() async {
        let fixture = signedInFixture(provider: "anthropic")
        let llm = QuotaLLMProvider(quota: quota(used: 25))
        let appState = makeAppState(
            llm: llm,
            secrets: fixture.secrets,
            persistence: fixture.persistence
        )
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isManagedProviderActive)

        await appState.refreshManagedQuota()

        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertEqual(appState.managedQuota?.used, 25)
    }

    func testRefreshManagedQuotaBackfillsStableAccountIDAndMigratesAlertState() async {
        let oldAccountKey = ManagedUsageAccountKey.make(from: "clerk-session:sess_legacy")
        let store = InMemoryUsageAlertStore()
        store.save(UsageAlertState(accountKey: oldAccountKey, windowResetsAt: window, firedThresholds: [50]))
        let notifier = FakeDraftNotifier()
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_legacy"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: 18,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            managedAccountEmail: "your Google account"
        ))
        let llm = QuotaLLMProvider(status: ManagedAccountStatus(
            userID: " user_123 ",
            quota: quota(used: 80)
        ))
        let appState = makeAppState(
            notifier: notifier,
            store: store,
            llm: llm,
            secrets: secrets,
            persistence: persistence
        )

        await appState.refreshManagedQuota()

        let newAccountKey = ManagedUsageAccountKey.make(from: "clerk-user:user_123")
        XCTAssertEqual(appState.managedAccountID, "clerk-user:user_123")
        XCTAssertEqual(persistence.loadSettings().managedAccountID, "clerk-user:user_123")
        XCTAssertEqual(appState.managedQuotaAccountKey, newAccountKey)
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.seventyFive])
        XCTAssertEqual(store.loadState(for: newAccountKey)?.firedThresholds, [50, 75])
    }

    func testDraftQuotaReportCapturedBeforeStableIDBackfillIsTranslated() async throws {
        let oldAccountKey = ManagedUsageAccountKey.make(from: "clerk-session:sess_legacy")
        let notifier = FakeDraftNotifier()
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_legacy"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: 18,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            managedAccountEmail: "your Google account"
        ))
        let llm = QuotaLLMProvider(status: ManagedAccountStatus(
            userID: "user_123",
            quota: quota(used: 20)
        ))
        let appState = makeAppState(
            notifier: notifier,
            llm: llm,
            secrets: secrets,
            persistence: persistence
        )

        let capturedKey = try XCTUnwrap(await appState.managedQuotaRelay.currentQuotaReportAccountKey())
        XCTAssertEqual(capturedKey, oldAccountKey)

        await appState.refreshManagedQuota()

        let newAccountKey = ManagedUsageAccountKey.make(from: "clerk-user:user_123")
        XCTAssertEqual(appState.managedQuotaAccountKey, newAccountKey)
        XCTAssertEqual(appState.managedQuota?.used, 20)

        await appState.managedQuotaRelay.reportQuota(quota(used: 80), accountKey: capturedKey)

        XCTAssertEqual(appState.managedQuotaAccountKey, newAccountKey)
        XCTAssertEqual(appState.managedQuota?.used, 80)
        XCTAssertEqual(notifier.usageAlerts.map(\.threshold), [.fifty, .seventyFive])
    }

    func testRefreshSkipsWhenNotSignedIn() async {
        let llm = QuotaLLMProvider(quota: quota(used: 50))
        let appState = makeAppState(llm: llm) // fresh install: managed but signed out
        XCTAssertFalse(appState.isManagedSignedIn)

        await appState.refreshManagedQuota()

        XCTAssertEqual(llm.fetchCount, 0, "no /v1/me fetch when not signed in")
        XCTAssertNil(appState.managedQuota)
    }

    func testSignOutClearsCachedManagedQuota() async {
        let appState = makeSignedInAppState()
        appState.ingestManagedQuota(quota(used: 55))
        XCTAssertNotNil(appState.managedQuota)
        XCTAssertNotNil(appState.managedQuotaAccountKey)

        await appState.signOutManaged()

        XCTAssertNil(appState.managedQuota)
        XCTAssertNil(appState.managedQuotaAccountKey)
    }

    func testRefreshManagedQuotaIgnoresResultAfterSignOut() async {
        let llm = BlockingQuotaLLMProvider()
        let appState = makeSignedInAppState(llm: llm)

        let refresh = Task { @MainActor in
            await appState.refreshManagedQuota()
        }
        await llm.waitUntilFetchStarted()
        await appState.signOutManaged()
        llm.completeFetch(with: quota(used: 50))
        await refresh.value

        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertNil(appState.managedQuota)
        XCTAssertNil(appState.managedQuotaAccountKey)
    }

    func testIsManagedQuotaExhausted() {
        let appState = makeSignedInAppState()
        XCTAssertFalse(appState.isManagedQuotaExhausted)
        appState.ingestManagedQuota(quota(used: 100))
        XCTAssertTrue(appState.isManagedQuotaExhausted)
    }
}
