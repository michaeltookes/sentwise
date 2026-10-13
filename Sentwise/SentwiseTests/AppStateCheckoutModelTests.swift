import XCTest
@testable import Sentwise

/// AppState wiring around the server-minted Paddle checkout model (item 56c).
@MainActor
final class AppStateCheckoutModelTests: XCTestCase {

    private final class CheckoutLLM: LLMProviding, @unchecked Sendable {
        var statusesToReturn: [ManagedAccountStatus?] = []
        var checkoutTransactionToReturn = PaddleCheckoutTransaction(transactionID: "txn_default")
        var checkoutError: Error?
        private(set) var fetchCount = 0
        private(set) var checkoutPriceIDs: [String] = []

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

        func complete(
            _ request: LLMRequest,
            provider: LLMProviderKind,
            apiKey: String,
            baseURL: String?
        ) async throws -> LLMResponse {
            LLMResponse(text: "")
        }

        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
            fetchCount += 1
            if !statusesToReturn.isEmpty {
                return statusesToReturn.removeFirst()
            }
            return nil
        }

        func createPaddleCheckoutTransaction(priceID: String) async throws -> PaddleCheckoutTransaction {
            checkoutPriceIDs.append(priceID)
            if let checkoutError { throw checkoutError }
            return checkoutTransactionToReturn
        }
    }

    private struct SignedInFixture {
        let appState: AppState
        let secrets: InMemorySecretStore
    }

    private func makeSignedInFixture(llm: LLMProviding) -> SignedInFixture {
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
        return SignedInFixture(appState: appState, secrets: secrets)
    }

    private func makeSignedInAppState(llm: LLMProviding) -> AppState {
        makeSignedInFixture(llm: llm).appState
    }

    private func status(
        userID: String = "user_marcus",
        plan: ManagedSubscription.Plan,
        statusValue: ManagedSubscription.Status
    ) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: userID,
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: plan, status: statusValue)
        )
    }

    func testCheckoutModelRoutesTierPriceAndCanOpen() {
        let llm = CheckoutLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = status(userID: "user_abc", plan: .trial, statusValue: .trialing)

        let model = appState.makeCheckoutModel(for: .starter, config: .active)

        // The Clerk id + email are no longer threaded client-side (item 56c): the
        // server-minted transaction carries the signed binding. The model just
        // routes the price and can open via the injected authed mint closure.
        XCTAssertTrue(model.canOpenCheckout)
        XCTAssertEqual(model.priceID, PaddleConfig.active.priceID(for: .starter))
    }

    // MARK: - Item 123: sandbox QA lane

    private let sandboxLane = ManagedBillingLane(
        environment: "sandbox",
        clientSideToken: "test_sandbox_token",
        prices: .init(starter: "pri_sbx_starter", pro: "pri_sbx_pro", unlimited: "pri_sbx_unlimited")
    )

    private func qaStatus(billing: ManagedBillingLane?) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: "user_qa",
            email: "qa-buyer@prowlqa.dev",
            subscription: ManagedSubscription(plan: .trial, status: .trialing),
            billing: billing
        )
    }

    func testQAAccountInSandboxLaneMintsCheckoutWithSandboxPrice() async {
        let llm = CheckoutLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = qaStatus(billing: sandboxLane)

        appState.presentBillingCheckout(plan: .pro)
        let request = try? XCTUnwrap(appState.billingCheckout)
        XCTAssertEqual(request?.config.environment, .sandbox)

        let model = appState.makeCheckoutModel(for: .pro, config: request?.config ?? .active)
        XCTAssertEqual(model.config.clientSideToken, "test_sandbox_token")
        await model.prepare()

        XCTAssertEqual(llm.checkoutPriceIDs, ["pri_sbx_pro"])
    }

    func testProductionAccountStaysOnLivePricesWhenServiceReportsSandbox() async {
        let llm = CheckoutLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .trial, status: .trialing),
            billing: sandboxLane
        )

        appState.presentBillingCheckout(plan: .pro)
        XCTAssertEqual(appState.billingCheckout?.config, PaddleConfig.production)
        XCTAssertEqual(appState.checkoutPaddleConfig, PaddleConfig.production)
    }

    // MARK: - Item 123 review: checkout waits for /v1/me

    func testCheckoutCannotStartBeforeAccountStatusLoads() {
        let llm = CheckoutLLM()
        let appState = makeSignedInAppState(llm: llm)
        XCTAssertNil(appState.managedAccountStatus)

        XCTAssertNil(appState.checkoutPaddleConfig)
        XCTAssertFalse(appState.canStartCheckout)
        appState.presentBillingCheckout(plan: .pro)
        XCTAssertNil(appState.billingCheckout, "no config may be captured before /v1/me loads")
        XCTAssertNil(appState.checkoutPaddleConfig, "still nothing to capture after a refused present")
    }

    func testCheckoutCapturesSandboxConfigOnceStatusArrives() async {
        let llm = CheckoutLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.presentBillingCheckout(plan: .pro)
        XCTAssertNil(appState.billingCheckout)

        appState.managedAccountStatus = qaStatus(billing: sandboxLane)
        XCTAssertTrue(appState.canStartCheckout)
        XCTAssertNil(appState.checkoutUnavailableMessage)
        appState.presentBillingCheckout(plan: .pro)
        guard let request = appState.billingCheckout else {
            return XCTFail("checkout should open once status is loaded")
        }

        // The request keeps the config it was opened with, even if status is
        // cleared afterwards (e.g. a refresh in flight).
        appState.managedAccountStatus = nil
        let model = appState.makeCheckoutModel(for: .pro, config: request.config)
        await model.prepare()
        XCTAssertEqual(model.config.environment, .sandbox)
        XCTAssertEqual(llm.checkoutPriceIDs, ["pri_sbx_pro"])
    }

    func testOlderWorkerWithoutBillingBlockFallsBackToProduction() {
        let llm = CheckoutLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = qaStatus(billing: nil)

        XCTAssertEqual(appState.checkoutPaddleConfig, PaddleConfig.production)
        appState.presentBillingCheckout()
        XCTAssertEqual(appState.billingCheckout?.config, PaddleConfig.production)
    }

    func testUnavailableSandboxLaneBlocksCheckoutForQAAccount() {
        let llm = CheckoutLLM()
        let appState = makeSignedInAppState(llm: llm)
        appState.managedAccountStatus = qaStatus(
            billing: ManagedBillingLane(environment: "sandbox", checkoutAvailable: false)
        )

        XCTAssertNil(appState.checkoutPaddleConfig)
        XCTAssertFalse(appState.canStartCheckout)
        appState.presentBillingCheckout()
        XCTAssertNil(appState.billingCheckout)
        XCTAssertEqual(
            appState.checkoutUnavailableMessage,
            "Checkout isn't available for this account right now."
        )
    }

    func testPlanChangeConfigWaitsForStatusOnlyForQAAccounts() {
        let llm = CheckoutLLM()
        let appState = makeSignedInAppState(llm: llm)
        // Persisted email marcus@example.com: snapshot-driven plan change stays production.
        XCTAssertEqual(appState.planChangePaddleConfig, PaddleConfig.production)

        appState.managedAccountEmail = "qa-buyer@prowlqa.dev"
        XCTAssertNil(appState.planChangePaddleConfig, "a QA account waits for /v1/me")

        appState.managedAccountStatus = qaStatus(billing: sandboxLane)
        XCTAssertEqual(appState.planChangePaddleConfig?.environment, .sandbox)
    }

    func testReconcileAfterCheckoutPollsWithoutDismissingTheSheet() async {
        let llm = CheckoutLLM()
        llm.statusesToReturn = [
            status(plan: .trial, statusValue: .trialing),
            status(plan: .starter, statusValue: .active)
        ]
        let appState = makeSignedInAppState(llm: llm)
        appState.billingCheckout = BillingCheckoutRequest(plan: .starter)

        await appState.reconcileSubscriptionAfterCheckout(refreshRetryDelays: [0])

        XCTAssertNotNil(appState.billingCheckout, "reconcile must NOT dismiss - the sheet shows the success state")
        XCTAssertEqual(llm.fetchCount, 2)
        XCTAssertTrue(appState.isOnActivePaidPlan)
    }

    func testMakeCheckoutModelMintsTransactionThroughAuthedLLM() async {
        let llm = CheckoutLLM()
        llm.checkoutTransactionToReturn = PaddleCheckoutTransaction(transactionID: "txn_from_worker")
        let appState = makeSignedInAppState(llm: llm)

        let model = appState.makeCheckoutModel(for: .pro, config: .active)
        XCTAssertTrue(model.canOpenCheckout)

        await model.prepare()
        model.pageDidLoad()

        XCTAssertEqual(llm.checkoutPriceIDs, [PaddleConfig.active.priceID(for: .pro)])
        XCTAssertEqual(model.openArgumentJSON, #"{"transactionId":"txn_from_worker"}"#)
    }

    func testMakeCheckoutModelSurfacesWorkerErrorAsFailure() async {
        let llm = CheckoutLLM()
        llm.checkoutError = LLMError.managedCheckoutFailed("Checkout is not configured.")
        let appState = makeSignedInAppState(llm: llm)

        let model = appState.makeCheckoutModel(for: .pro, config: .active)
        await model.prepare()

        XCTAssertEqual(model.phase, .failed("Checkout is not configured."))
    }

    func testMakeCheckoutModelReconcilesAuthFailureBeforeSurfacingFailure() async {
        let llm = CheckoutLLM()
        llm.checkoutError = LLMError.managedNotSignedIn
        let fixture = makeSignedInFixture(llm: llm)
        let appState = fixture.appState
        appState.managedAccountStatus = status(plan: .trial, statusValue: .trialing)
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertNoThrow(try fixture.secrets.remove(.managedClientToken))
        XCTAssertNoThrow(try fixture.secrets.remove(.managedSessionID))

        let model = appState.makeCheckoutModel(for: .pro, config: .active)
        await model.prepare()

        XCTAssertEqual(model.phase, .failed("Sign in to Sentwise AI before subscribing."))
        XCTAssertEqual(llm.checkoutPriceIDs, [PaddleConfig.active.priceID(for: .pro)])
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertTrue(appState.managedAccountEmail.isEmpty)
        XCTAssertNil(appState.managedAccountStatus)
    }
}
