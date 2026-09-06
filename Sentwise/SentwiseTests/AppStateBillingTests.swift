import XCTest
@testable import Sentwise

/// AppState-level checkout + licensing behavior for item 56c: Clerk-user-id
/// threading, the subscribe/manage-billing CTAs, and the offline license grace
/// backed by the cached subscription snapshot.
@MainActor
final class AppStateBillingTests: XCTestCase {

    // MARK: - Doubles

    /// An `LLMProviding` that returns a fixed `/v1/me` status.
    private final class StatusLLM: LLMProviding, @unchecked Sendable {
        var statusToReturn: ManagedAccountStatus?
        var statusesToReturn: [ManagedAccountStatus?] = []
        var fetchError: Error?
        private(set) var fetchCount = 0

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
            LLMResponse(text: "")
        }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
            fetchCount += 1
            if let fetchError { throw fetchError }
            if !statusesToReturn.isEmpty {
                return statusesToReturn.removeFirst()
            }
            return statusToReturn
        }
        func fetchManagedQuota() async throws -> ManagedQuota? { statusToReturn?.quota }
        func deleteManagedAccount() async throws {}
    }

    // MARK: - Fixture

    private func makeSignedInAppState(
        email: String = "marcus@example.com",
        llm: LLMProviding,
        cacheStore: SubscriptionCacheStoring? = nil
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
            managedAccountEmail: email,
            managedAccountID: "clerk-user:user_marcus"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: FakeDraftNotifier()
        )
        if let cacheStore { appState.subscriptionCacheStore = cacheStore }
        return appState
    }

    private func status(
        userID: String = "user_marcus",
        plan: ManagedSubscription.Plan,
        statusValue: ManagedSubscription.Status,
        billingURL: String? = nil,
        renewsAt: Date? = nil
    ) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: userID,
            email: "marcus@example.com",
            subscription: ManagedSubscription(
                plan: plan, status: statusValue, renewsAt: renewsAt, manageBillingURL: billingURL
            )
        )
    }

    private func legacyTrialStatus(active: Bool) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            trial: ManagedTrial(active: active)
        )
    }

    // MARK: - Clerk user id threading

    func testClerkUserIDPrefersLiveStatus() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(userID: "user_live", plan: .pro, statusValue: .active)
        XCTAssertEqual(appState.managedClerkUserID, "user_live")
    }

    func testClerkUserIDFallsBackToPersistedAccountID() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        // No live status yet -> parse "clerk-user:user_marcus".
        XCTAssertEqual(appState.managedClerkUserID, "user_marcus")
    }

    // MARK: - Subscribe CTA routing

    func testTrialingOffersSubscribeAndPresentsPicker() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(plan: .trial, statusValue: .trialing)
        XCTAssertTrue(appState.shouldOfferSubscribe)

        appState.presentBillingCheckout()
        XCTAssertNotNil(appState.billingCheckout)
        XCTAssertNil(appState.billingCheckout?.plan, "no plan -> the sheet shows the picker")
    }

    func testActivePaidPlanDoesNotOfferSubscribe() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(plan: .pro, statusValue: .active)
        XCTAssertTrue(appState.isOnActivePaidPlan)
        XCTAssertFalse(appState.shouldOfferSubscribe)
    }

    func testPresentBillingCheckoutForSpecificTier() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(plan: .trial, statusValue: .trialing)
        appState.presentBillingCheckout(plan: .unlimited)
        XCTAssertEqual(appState.billingCheckout?.plan, .unlimited)
    }

    func testActivePaidPlanCannotPresentNewCheckout() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(plan: .pro, statusValue: .active)

        appState.presentBillingCheckout()

        XCTAssertNil(appState.billingCheckout)
    }

    func testPastDuePaidPlanUsesManageBillingInsteadOfNewCheckout() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(
            plan: .pro,
            statusValue: .pastDue,
            billingURL: "https://billing.example/portal"
        )

        XCTAssertFalse(appState.isOnActivePaidPlan)
        XCTAssertTrue(appState.hasManageablePaidSubscription)
        XCTAssertFalse(appState.shouldOfferSubscribe)

        appState.presentBillingCheckout()
        XCTAssertNil(appState.billingCheckout)
        XCTAssertTrue(appState.canManageBilling)
    }

    func testCachedPaidSubscriptionBlocksNewCheckoutWhenLiveStatusUnavailable() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .active,
            manageBillingURL: "https://billing.example/portal",
            capturedAt: Date()
        )

        XCTAssertTrue(appState.hasManageablePaidSubscription)
        XCTAssertFalse(appState.shouldOfferSubscribe)

        appState.presentBillingCheckout()
        XCTAssertNil(appState.billingCheckout)
        XCTAssertTrue(appState.canManageBilling)
    }

    func testCheckoutModelThreadsClerkIDAndEmail() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(userID: "user_abc", plan: .trial, statusValue: .trialing)
        let model = appState.makeCheckoutModel(for: .starter)
        XCTAssertEqual(model.clerkUserID, "user_abc")
        XCTAssertEqual(model.email, "marcus@example.com")
        XCTAssertEqual(model.priceID, PaddleConfig.active.priceID(for: .starter))
    }

    // MARK: - Manage billing enable/disable

    func testManageBillingDisabledWhenNoURL() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(plan: .trial, statusValue: .trialing, billingURL: nil)
        XCTAssertFalse(appState.canManageBilling)
        XCTAssertNil(appState.manageBillingURL)
    }

    func testManageBillingEnabledWhenURLPresent() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(
            plan: .pro, statusValue: .active, billingURL: "https://sandbox-customer-portal.paddle.com/abc"
        )
        XCTAssertTrue(appState.canManageBilling)
        XCTAssertEqual(appState.manageBillingURL?.absoluteString, "https://sandbox-customer-portal.paddle.com/abc")
    }

    func testManageBillingRejectsNonHTTPURL() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(plan: .pro, statusValue: .active, billingURL: "javascript:alert(1)")
        XCTAssertNil(appState.manageBillingURL)
    }

    func testManageBillingRequiresExactHTTPOrHTTPSScheme() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm)

        appState.managedAccountStatus = status(plan: .pro, statusValue: .active, billingURL: "HTTPS://billing.example/portal")
        XCTAssertEqual(appState.manageBillingURL?.scheme?.lowercased(), "https")

        appState.managedAccountStatus = status(plan: .pro, statusValue: .active, billingURL: "httpx://billing.example/portal")
        XCTAssertNil(appState.manageBillingURL)

        appState.managedAccountStatus = status(plan: .pro, statusValue: .active, billingURL: "http-evil://billing.example/portal")
        XCTAssertNil(appState.manageBillingURL)
    }

    // MARK: - Checkout completion refresh

    func testCompleteBillingCheckoutRetriesUntilPaidSubscriptionVisible() async {
        let llm = StatusLLM()
        llm.statusesToReturn = [
            status(plan: .trial, statusValue: .trialing),
            status(plan: .pro, statusValue: .active)
        ]
        let appState = makeSignedInAppState(llm: llm)
        appState.billingCheckout = BillingCheckoutRequest()

        await appState.completeBillingCheckout(refreshRetryDelays: [0])

        XCTAssertNil(appState.billingCheckout)
        XCTAssertEqual(llm.fetchCount, 2)
        XCTAssertTrue(appState.isOnActivePaidPlan)
    }

    func testCompleteBillingCheckoutReconcilesAfterImmediateRetryBudget() async throws {
        let llm = StatusLLM()
        llm.statusesToReturn = [
            status(plan: .trial, statusValue: .trialing),
            status(plan: .trial, statusValue: .trialing),
            status(plan: .pro, statusValue: .active)
        ]
        let appState = makeSignedInAppState(llm: llm)
        defer { appState.cancelBillingReconciliation() }

        await appState.completeBillingCheckout(refreshRetryDelays: [0], reconciliationRetryDelays: [0])
        for _ in 0..<1_000 where llm.fetchCount < 3 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(llm.fetchCount, 3)
        XCTAssertTrue(appState.isOnActivePaidPlan)
        XCTAssertNil(appState.billingReconciliationTask)
    }

    // MARK: - Offline license grace

    func testRefreshRecordsSnapshotAndEntitlesWhenOnline() async {
        let llm = StatusLLM()
        llm.statusToReturn = status(plan: .pro, statusValue: .active)
        let store = InMemorySubscriptionCacheStore()
        let appState = makeSignedInAppState(llm: llm, cacheStore: store)

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.status, .active)
        XCTAssertFalse(store.saved.isEmpty, "the snapshot should be persisted to the durable store")
        XCTAssertEqual(appState.managedLicense, .entitled)
    }

    func testRefreshFailureFallsBackToSnapshotForLicenseFreshness() async {
        let llm = StatusLLM()
        llm.statusToReturn = status(plan: .pro, statusValue: .active)
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())

        await appState.refreshManagedQuota()
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedLicense, .entitled)

        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .active,
            capturedAt: Date().addingTimeInterval(-8 * 86_400)
        )
        llm.fetchError = NSError(domain: "AppStateBillingTests", code: 1)

        await appState.refreshManagedQuota()

        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedAccountStatus?.subscription?.status, .active)
        XCTAssertEqual(appState.managedLicense, .unknown)
    }

    func testManagedLLMRequestsRequireEntitledOrGraceLicense() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())
        XCTAssertTrue(appState.isLLMConnected)

        appState.managedAccountStatus = status(plan: .pro, statusValue: .pastDue)
        appState.managedAccountStatusIsFresh = true

        XCTAssertEqual(appState.managedLicense, .notEntitled)
        XCTAssertFalse(appState.managedLicenseAllowsLLMRequests)
        XCTAssertNil(appState.currentDraftLLMConfiguration)

        appState.managedAccountStatus = nil
        appState.managedAccountStatusIsFresh = false
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(plan: .pro, status: .active, capturedAt: Date())

        guard case .grace = appState.managedLicense else {
            return XCTFail("expected cached active subscription to allow grace")
        }
        XCTAssertTrue(appState.managedLicenseAllowsLLMRequests)
        XCTAssertNotNil(appState.currentDraftLLMConfiguration)
    }

    func testManagedLicenseDerivesTrialEntitlementWhenSubscriptionIsOmitted() async {
        let llm = StatusLLM()
        llm.statusToReturn = legacyTrialStatus(active: true)
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.managedLicense, .entitled)
        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.plan, .trial)
        XCTAssertEqual(appState.cachedSubscriptionSnapshot?.status, .trialing)
    }

    func testExpiredFreshStatusFallsBackToSnapshotGraceWindow() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())
        appState.managedAccountStatus = status(plan: .pro, statusValue: .active)
        appState.managedAccountStatusFreshUntil = Date().addingTimeInterval(-1)
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .active,
            capturedAt: Date().addingTimeInterval(-8 * 86_400)
        )

        XCTAssertFalse(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedLicense, .unknown)
    }

    func testStaleOnlineManagedLicenseRefreshesBeforeRequestGating() async {
        let llm = StatusLLM()
        llm.statusToReturn = status(plan: .pro, statusValue: .active)
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }
        appState.managedAccountStatus = status(plan: .pro, statusValue: .active)
        appState.managedAccountStatusFreshUntil = Date().addingTimeInterval(-1)
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .active,
            capturedAt: Date().addingTimeInterval(-8 * 86_400)
        )

        XCTAssertEqual(appState.managedLicense, .unknown)

        await appState.refreshManagedQuotaIfLicenseStatusStale()

        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedLicense, .entitled)
    }

    func testScheduledManagedStatusRefreshRunsWhenFreshnessIsNearExpiry() async throws {
        let llm = StatusLLM()
        llm.statusToReturn = status(plan: .pro, statusValue: .active)
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }
        appState.managedAccountStatusFreshUntil = Date().addingTimeInterval(0.01)

        appState.scheduleManagedAccountStatusRefreshBeforeExpiry()

        for _ in 0..<100 where llm.fetchCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(llm.fetchCount, 1)
        XCTAssertTrue(appState.managedAccountStatusIsFresh)
        XCTAssertEqual(appState.managedLicense, .entitled)
    }

    func testTrialFreshnessDeadlineIsCappedAtKnownTrialEnd() {
        let llm = StatusLLM()
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())
        let endsAt = Date().addingTimeInterval(300)
        let trialing = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            trial: ManagedTrial(endsAt: endsAt, active: true),
            subscription: ManagedSubscription(plan: .trial, status: .trialing)
        )

        appState.markManagedAccountStatusFresh(from: trialing)

        XCTAssertEqual(
            appState.managedAccountStatusFreshUntil?.timeIntervalSince1970 ?? 0,
            endsAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testInitialWatchStartRefreshesAndResumesAfterManagedLicenseRecovery() async {
        let llm = StatusLLM()
        llm.statusToReturn = status(plan: .pro, statusValue: .active)
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "app-pw"
        appState.isAccountConnected = true

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

    func testWatcherLicensePausePreservesResumeIntentAndRestartsAfterRecovery() async {
        let llm = StatusLLM()
        llm.statusToReturn = status(plan: .pro, statusValue: .active)
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "app-pw"
        appState.isAccountConnected = true
        let pastDue = status(plan: .pro, statusValue: .pastDue)
        appState.managedAccountStatus = pastDue
        appState.markManagedAccountStatusFresh(from: pastDue)
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.watchStatus, .paused)
        XCTAssertTrue(appState.resumeWatchingAfterManagedReauth)

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.watchStatus, .watching)
        XCTAssertFalse(appState.resumeWatchingAfterManagedReauth)
        appState.stopWatching()
    }

    func testOfflineFallsBackToCachedSnapshotWithinGrace() async {
        let llm = StatusLLM()
        llm.statusToReturn = status(plan: .pro, statusValue: .active)
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())

        // Capture a good snapshot while "online".
        await appState.refreshManagedQuota()
        XCTAssertEqual(appState.managedLicense, .entitled)

        // Go offline and lose the live status: grace keeps the app entitled.
        appState.isOnline = false
        appState.managedAccountStatus = nil
        guard case .grace = appState.managedLicense else {
            return XCTFail("offline within grace should be .grace, got \(appState.managedLicense)")
        }
    }

    func testSignOutClearsInMemorySnapshot() async {
        let llm = StatusLLM()
        llm.statusToReturn = status(plan: .pro, statusValue: .active)
        let appState = makeSignedInAppState(llm: llm, cacheStore: InMemorySubscriptionCacheStore())
        await appState.refreshManagedQuota()
        XCTAssertNotNil(appState.cachedSubscriptionSnapshot)

        appState.clearManagedQuotaCache()
        XCTAssertNil(appState.cachedSubscriptionSnapshot)
    }

    // MARK: - Test double

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        private(set) var saved: [String: SubscriptionSnapshot] = [:]
        func snapshot(accountKey: String) -> SubscriptionSnapshot? { saved[accountKey] }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) { saved[accountKey] = snapshot }
        func clear(accountKey: String) { saved[accountKey] = nil }
    }
}
