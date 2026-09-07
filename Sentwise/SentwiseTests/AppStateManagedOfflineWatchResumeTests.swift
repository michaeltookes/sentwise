import XCTest
@testable import Sentwise

@MainActor
final class AppStateManagedOfflineWatchResumeTests: XCTestCase {

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

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        func snapshot(accountKey: String) -> SubscriptionSnapshot? { nil }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) {}
        func clear(accountKey: String) {}
    }

    func testInitialWatchStartPreservesManagedLicenseRecoveryIntentWhileOffline() async {
        let llm = StatusLLM()
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active)
        )
        let reachability = FakeReachabilityMonitor(isOnline: false, hasCurrentPath: true)
        let appState = makeSignedInAppState(llm: llm, reachability: reachability)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "app-pw"
        appState.isAccountConnected = true

        appState.startWatchingIfReady()

        XCTAssertEqual(appState.watchStatus, .idle)
        XCTAssertTrue(appState.resumeWatchingAfterManagedReauth)
        XCTAssertEqual(llm.fetchCount, 0)

        reachability.setOnline(true)
        for _ in 0..<1_000 where appState.watchStatus != .watching {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertGreaterThanOrEqual(llm.fetchCount, 1)
        XCTAssertEqual(appState.watchStatus, .watching)
        XCTAssertFalse(appState.resumeWatchingAfterManagedReauth)
        appState.stopWatching()
    }

    private func makeSignedInAppState(
        llm: LLMProviding,
        reachability: NetworkReachabilityMonitoring
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
            managedAccountID: "clerk-user:user_marcus"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: FakeDraftNotifier(),
            reachability: reachability
        )
        appState.subscriptionCacheStore = InMemorySubscriptionCacheStore()
        return appState
    }
}
