import XCTest
@testable import Sentwise

@MainActor
final class AppStateManagedStatusOrderingTests: XCTestCase {

    private final class DeferredStatusLLM: LLMProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var pendingFetches: [CheckedContinuation<ManagedAccountStatus?, Error>?] = []
        private var fetchCallCount = 0

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

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        private(set) var saved: [String: SubscriptionSnapshot] = [:]

        func snapshot(accountKey: String) -> SubscriptionSnapshot? { saved[accountKey] }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) { saved[accountKey] = snapshot }
        func clear(accountKey: String) { saved[accountKey] = nil }
    }
}
