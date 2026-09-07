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
        return AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: FakeDraftNotifier()
        )
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

        let model = appState.makeCheckoutModel(for: .starter)

        // The Clerk id + email are no longer threaded client-side (item 56c): the
        // server-minted transaction carries the signed binding. The model just
        // routes the price and can open via the injected authed mint closure.
        XCTAssertTrue(model.canOpenCheckout)
        XCTAssertEqual(model.priceID, PaddleConfig.active.priceID(for: .starter))
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

        let model = appState.makeCheckoutModel(for: .pro)
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

        let model = appState.makeCheckoutModel(for: .pro)
        await model.prepare()

        XCTAssertEqual(model.phase, .failed("Checkout is not configured."))
    }
}
