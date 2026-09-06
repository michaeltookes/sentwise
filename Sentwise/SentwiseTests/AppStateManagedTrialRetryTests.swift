import XCTest
@testable import Sentwise

@MainActor
final class AppStateManagedTrialRetryTests: XCTestCase {

    private final class StatusLLM: LLMProviding, @unchecked Sendable {
        var statusToReturn: ManagedAccountStatus?
        var statusesToReturn: [ManagedAccountStatus?] = []
        private(set) var fetchCount = 0

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
            LLMResponse(text: "")
        }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
            fetchCount += 1
            if !statusesToReturn.isEmpty {
                return statusesToReturn.removeFirst()
            }
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

    func testTrialFreshnessDeadlineFallsBackToSubscriptionRenewalDate() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        let renewsAt = Date().addingTimeInterval(300)
        let trialing = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .trial, status: .trialing, renewsAt: renewsAt)
        )

        appState.markManagedAccountStatusFresh(from: trialing)

        XCTAssertEqual(
            appState.managedAccountStatusFreshUntil?.timeIntervalSince1970 ?? 0,
            renewsAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testBillingPortalReturnRefreshesManagedStatus() async {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        let portalURL = "https://billing.example/portal"
        let pastDue = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .pastDue, manageBillingURL: portalURL)
        )
        appState.managedAccountStatus = pastDue
        appState.markManagedAccountStatusFresh(from: pastDue)
        var openedURL: URL?

        appState.openManageBilling { openedURL = $0 }

        XCTAssertEqual(openedURL?.absoluteString, portalURL)
        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertTrue(appState.billingPortalRefreshPending)

        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active, manageBillingURL: portalURL)
        )
        await appState.refreshManagedQuotaAfterBillingPortalReturnIfNeeded()

        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertFalse(appState.billingPortalRefreshPending)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.status, .active)
        XCTAssertEqual(appState.managedLicense, .entitled)
    }

    func testBillingPortalReturnReconcilesAfterInitialPastDueRefresh() async throws {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelBillingReconciliation() }
        let portalURL = "https://billing.example/portal"
        let pastDue = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .pastDue, manageBillingURL: portalURL)
        )
        appState.managedAccountStatus = pastDue
        appState.markManagedAccountStatusFresh(from: pastDue)
        appState.openManageBilling { _ in }
        llm.statusesToReturn = [
            pastDue,
            ManagedAccountStatus(
                userID: "user_marcus",
                email: "marcus@example.com",
                subscription: ManagedSubscription(plan: .pro, status: .active, manageBillingURL: portalURL)
            )
        ]

        await appState.refreshManagedQuotaAfterBillingPortalReturnIfNeeded(reconciliationRetryDelays: [0])
        for _ in 0..<1_000 where llm.fetchCount < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(llm.fetchCount, 2)
        XCTAssertFalse(appState.billingPortalRefreshPending)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.status, .active)
        XCTAssertEqual(appState.managedLicense, .entitled)
        XCTAssertNil(appState.billingReconciliationTask)
    }

    func testInitialWatchStartRefreshesAndResumesAfterStaleNotEntitledLicenseRecovery() async {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .pastDue,
            capturedAt: Date()
        )
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "app-pw"
        appState.isAccountConnected = true
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active)
        )

        XCTAssertEqual(appState.managedLicense, .notEntitled)
        XCTAssertFalse(appState.canWatch)
        appState.startWatchingIfReady()

        for _ in 0..<1_000 where appState.watchStatus != .watching {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertGreaterThanOrEqual(llm.fetchCount, 1)
        XCTAssertEqual(appState.watchStatus, .watching)
        XCTAssertFalse(appState.resumeWatchingAfterManagedReauth)
        appState.stopWatching()
    }

    func testFreshPastDueRefreshKeepsWatcherResumeIntent() async {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.watchStatus = .paused
        appState.resumeWatchingAfterManagedReauth = true
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .pastDue)
        )

        await appState.refreshManagedQuota()

        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedLicense, .notEntitled)
        XCTAssertTrue(appState.resumeWatchingAfterManagedReauth)
    }

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        func snapshot(accountKey: String) -> SubscriptionSnapshot? { nil }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) {}
        func clear(accountKey: String) {}
    }
}
