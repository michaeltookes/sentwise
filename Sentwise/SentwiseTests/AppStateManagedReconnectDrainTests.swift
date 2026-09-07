import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateManagedReconnectDrainTests: XCTestCase {

    private final class SuspendedManagedStatusLLM: LLMProviding, @unchecked Sendable {
        let didStartFetch = XCTestExpectation(description: "managed status fetch started")
        private let lock = NSLock()
        private var fetchContinuation: CheckedContinuation<ManagedAccountStatus?, Error>?
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
                fetchContinuation = continuation
                lock.unlock()
                didStartFetch.fulfill()
            }
        }

        func fetchManagedQuota() async throws -> ManagedQuota? { nil }
        func deleteManagedAccount() async throws {}

        func completeFetch(with result: Result<ManagedAccountStatus?, Error>) {
            lock.lock()
            let continuation = fetchContinuation
            fetchContinuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    private func pendingDraft() -> Draft {
        Draft(
            id: 1,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: "Lunch?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: Lunch?",
            body: "Thursday works!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
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

    func testManagedReconnectDrainsQueuedDraftsBeforeStatusRefreshCompletes() async {
        var queuedDraft = pendingDraft()
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend, force: true)
        queuedDraft.offlineQueuedDispatch = intent

        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "managed",
                managedAccountEmail: "marcus@example.com",
                managedAccountID: "clerk-user:user_marcus",
                sendBehavior: SendBehavior.autoSend.rawValue,
                sendDelaySeconds: 0
            ),
            pendingDrafts: [queuedDraft]
        )
        let provider = ResilienceMailProvider(sendResults: [.success(())])
        let reachability = FakeReachabilityMonitor(isOnline: false)
        let llm = SuspendedManagedStatusLLM()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: llm,
            notifier: FakeDraftNotifier(),
            reachability: reachability
        )
        appState.pendingDrafts = [queuedDraft]
        appState.pendingDraftCount = 1
        appState.retryRunner = .immediate
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }

        appState.startReachabilityMonitoring()
        reachability.setOnline(true)

        await fulfillment(of: [llm.didStartFetch], timeout: 1)
        await waitUntil { provider.sendCallCount == 1 }
        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertTrue(appState.offlineQueuedDispatch.isEmpty)
        XCTAssertFalse(appState.isWaitingForNetwork(queuedDraft.identity))

        let active = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active)
        )
        llm.completeFetch(with: .success(active))
        await waitUntil { appState.managedAccountStatusIsFresh }
    }
}
