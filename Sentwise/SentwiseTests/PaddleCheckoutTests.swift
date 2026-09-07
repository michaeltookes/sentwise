import XCTest
@testable import Sentwise

/// Checkout wiring for item 56c: price-id routing, the server-minted-transaction
/// `Paddle.Checkout.open` argument shape (`{ transactionId }`), bridge-event
/// mapping, and the checkout view-model's async prepare → open → phase machine —
/// all exercised without a live Paddle overlay or a live Worker.
final class PaddleCheckoutTests: XCTestCase {

    // MARK: - Config / price-id routing

    func testActiveConfigIsSandboxWithEmbeddedCredentials() {
        let config = PaddleConfig.active
        XCTAssertEqual(config.environment, .sandbox)
        XCTAssertEqual(config.clientSideToken, "test_7a55409b65e7f906b94b863e63a")
        XCTAssertEqual(config.paddleJSEnvironment, "sandbox")
    }

    func testPriceIDRoutingPerTier() {
        let config = PaddleConfig.active
        XCTAssertEqual(config.priceID(for: .starter), "pri_01m1syd7nfarp8pggpcnvjbgyy")
        XCTAssertEqual(config.priceID(for: .pro), "pri_01m1symsxarc4c3jdea0ntb09w")
        XCTAssertEqual(config.priceID(for: .unlimited), "pri_01m1syrdg05f49kz705gbzn6tz")
    }

    func testEveryPurchasablePlanMapsToADistinctPrice() {
        let config = PaddleConfig.active
        let ids = Set(PaddlePlan.allCases.map { config.priceID(for: $0) })
        XCTAssertEqual(ids.count, PaddlePlan.allCases.count)
        XCTAssertFalse(ids.contains(""))
    }

    // MARK: - Overlay-open argument JSON (transaction id only)

    func testArgumentJSONCarriesOnlyTransactionID() throws {
        let request = PaddleCheckoutRequest(transactionID: "txn_01abc")
        let json = try request.makeArgumentJSONString()
        XCTAssertEqual(json, #"{"transactionId":"txn_01abc"}"#, json)
    }

    func testArgumentJSONNeverCarriesClientSideBinding() throws {
        // The whole point of 56c: no items/customData/customer/clerkUserId is sent
        // client-side — the signed binding lives server-side on the transaction.
        let json = try PaddleCheckoutRequest(transactionID: "txn_x").makeArgumentJSONString()
        for forbidden in ["items", "customData", "customer", "clerkUserId", "priceId"] {
            XCTAssertFalse(json.contains(forbidden), "\(forbidden) must not appear: \(json)")
        }
    }

    // MARK: - Bridge-event mapping

    func testBridgeEventMapping() {
        XCTAssertEqual(PaddleBridgeEvent.make(name: "checkout.completed"), .completed)
        XCTAssertEqual(PaddleBridgeEvent.make(name: "checkout.closed"), .closed)
        // The overlay actually opened — paddle.opened / checkout.loaded.
        XCTAssertEqual(PaddleBridgeEvent.make(name: "paddle.opened"), .ready)
        XCTAssertEqual(PaddleBridgeEvent.make(name: "checkout.loaded"), .ready)
        // paddle.ready is init-only now (before any overlay opens) → ignored.
        XCTAssertEqual(PaddleBridgeEvent.make(name: "paddle.ready"), .ignored("paddle.ready"))
        XCTAssertEqual(PaddleBridgeEvent.make(name: "checkout.warning"), .ignored("checkout.warning"))
        if case .failed = PaddleBridgeEvent.make(name: "checkout.error", detail: "card declined") {} else {
            XCTFail("checkout.error should map to .failed")
        }
    }

    func testBridgeCheckoutErrorExtractsMessageFromSerializedPayload() {
        let payload = #"""
        {"name":"checkout.error","error":{"detail":"card declined","message":"declined"},"customer":{"email":"marcus@example.com"}}
        """#
        XCTAssertEqual(PaddleBridgeEvent.make(name: "checkout.error", detail: payload), .failed("card declined"))
    }

    func testBridgeCheckoutErrorHidesSerializedPayloadWithoutMessage() {
        let payload = #"{"name":"checkout.error","customer":{"email":"marcus@example.com"}}"#
        guard case .failed(let message) = PaddleBridgeEvent.make(name: "checkout.error", detail: payload) else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(message, "Checkout couldn't be completed. Please try again.")
        XCTAssertFalse(message.contains("marcus@example.com"))
    }

    func testBridgeErrorWithoutDetailStillHasUserSafeMessage() {
        guard case .failed(let message) = PaddleBridgeEvent.make(name: "paddle.failed") else {
            return XCTFail("expected .failed")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Model doubles

    /// A transaction-minting closure that returns a fixed transaction or throws.
    private func mint(
        _ transactionID: String = "txn_01test",
        error: Error? = nil
    ) -> @Sendable (String) async throws -> PaddleCheckoutTransaction {
        return { _ in
            if let error { throw error }
            return PaddleCheckoutTransaction(transactionID: transactionID)
        }
    }

    // MARK: - View-model: routing + preparation

    @MainActor
    func testModelRoutesPriceForPlan() {
        let model = PaddleCheckoutModel(plan: .unlimited, createTransaction: mint())
        XCTAssertEqual(model.priceID, PaddleConfig.active.priceID(for: .unlimited))
    }

    @MainActor
    func testModelWithoutTransactionSourceCannotOpenAndFailsToPrepare() async {
        let model = PaddleCheckoutModel(plan: .pro, createTransaction: nil)
        XCTAssertFalse(model.canOpenCheckout)
        await model.prepare()
        guard case .failed = model.phase else { return XCTFail("expected failed") }
    }

    @MainActor
    func testPrepareThenPageLoadPublishesTransactionArgument() async {
        let model = PaddleCheckoutModel(plan: .starter, createTransaction: mint("txn_starter"))
        await model.prepare()
        XCTAssertEqual(model.phase, .preparing, "still awaiting page load before opening")
        XCTAssertNil(model.openArgumentJSON, "must not open before the page is ready")

        model.pageDidLoad()
        XCTAssertEqual(model.openArgumentJSON, #"{"transactionId":"txn_starter"}"#)
    }

    @MainActor
    func testPageLoadBeforePrepareStillOpensOnceTransactionArrives() async {
        let model = PaddleCheckoutModel(plan: .pro, createTransaction: mint("txn_pro"))
        model.pageDidLoad()
        XCTAssertNil(model.openArgumentJSON, "no transaction yet")
        await model.prepare()
        XCTAssertEqual(model.openArgumentJSON, #"{"transactionId":"txn_pro"}"#)
    }

    @MainActor
    func testPrepareIsIdempotent() async {
        var calls = 0
        let counting: @Sendable (String) async throws -> PaddleCheckoutTransaction = { _ in
            calls += 1
            return PaddleCheckoutTransaction(transactionID: "txn_1")
        }
        let model = PaddleCheckoutModel(plan: .pro, createTransaction: counting)
        await model.prepare()
        await model.prepare()
        XCTAssertEqual(calls, 1)
    }

    // MARK: - View-model: endpoint errors → friendly .failed

    @MainActor
    func testCheckoutEndpointErrorSurfacesWorkerMessage() async {
        let model = PaddleCheckoutModel(
            plan: .pro,
            createTransaction: mint(error: LLMError.managedCheckoutFailed("That plan isn't available right now."))
        )
        await model.prepare()
        XCTAssertEqual(model.phase, .failed("That plan isn't available right now."))
        XCTAssertNil(model.openArgumentJSON)
    }

    @MainActor
    func testNotSignedInErrorSurfacesSignInCopy() async {
        let model = PaddleCheckoutModel(
            plan: .pro,
            createTransaction: mint(error: LLMError.managedNotSignedIn)
        )
        await model.prepare()
        XCTAssertEqual(model.phase, .failed("Sign in to Sentwise AI before subscribing."))
    }

    @MainActor
    func testTransportErrorSurfacesConnectionCopy() async {
        let model = PaddleCheckoutModel(
            plan: .pro,
            createTransaction: mint(error: LLMError.transport("offline"))
        )
        await model.prepare()
        guard case .failed(let message) = model.phase else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("connection"), message)
    }

    @MainActor
    func testFailureCopyIsBillingOnlyNoPrivacyClaims() async {
        // Guard the copy rule: billing/confirmation strings must not make
        // privacy/retention claims (gated).
        let messages = [
            PaddleCheckoutModel.friendlyMessage(for: LLMError.managedNotSignedIn),
            PaddleCheckoutModel.friendlyMessage(for: LLMError.managedCheckoutFailed("Nope.")),
            PaddleCheckoutModel.friendlyMessage(for: LLMError.transport("x")),
            PaddleCheckoutModel.friendlyMessage(for: LLMError.invalidResponse("x"))
        ]
        for message in messages {
            for banned in ["never stored", "zero-retention", "zero retention", "not stored", "never trained"] {
                XCTAssertFalse(message.lowercased().contains(banned), "\(message) leaks a privacy claim")
            }
        }
    }

    // MARK: - View-model: phase machine

    @MainActor
    func testOpenedThenCompletedTransitions() async {
        let model = PaddleCheckoutModel(plan: .pro, createTransaction: mint())
        await model.prepare()
        model.pageDidLoad()
        XCTAssertEqual(model.phase, .preparing)
        model.handle(.ready) // paddle.opened
        XCTAssertEqual(model.phase, .presenting)
        model.handle(.completed)
        XCTAssertEqual(model.phase, .completed)
    }

    @MainActor
    func testReadyBeforeOverlayAdvancesFromPreparing() async {
        // Even if the transaction/page race leaves us in .preparing, the real
        // overlay-open signal advances us to presenting.
        let model = PaddleCheckoutModel(plan: .pro, createTransaction: mint())
        model.handle(.ready)
        XCTAssertEqual(model.phase, .presenting)
    }

    @MainActor
    func testCloseAfterCompletionIsIgnored() {
        let model = PaddleCheckoutModel(plan: .pro, createTransaction: mint())
        model.handle(.completed)
        model.handle(.closed)
        XCTAssertEqual(model.phase, .completed, "a close after completion must not overwrite the win")
    }

    @MainActor
    func testCloseWithoutCompletionTransitionsToClosed() {
        let model = PaddleCheckoutModel(plan: .pro, createTransaction: mint())
        model.handle(.ready)
        model.handle(.closed)
        XCTAssertEqual(model.phase, .closed)
    }

    @MainActor
    func testFailedTransitionAndTerminalStickiness() {
        let model = PaddleCheckoutModel(plan: .pro, createTransaction: mint())
        model.handle(.failed("boom"))
        XCTAssertEqual(model.phase, .failed("boom"))
        // A later ready must not resurrect a failed checkout.
        model.handle(.ready)
        XCTAssertEqual(model.phase, .failed("boom"))
        // But a completion still wins (Paddle can complete despite a prior warning).
        model.handle(.completed)
        XCTAssertEqual(model.phase, .completed)
    }

    @MainActor
    func testOpenArgumentNotPublishedOnceTerminal() async {
        let model = PaddleCheckoutModel(plan: .pro, createTransaction: mint())
        model.handle(.failed("boom"))
        await model.prepare()
        model.pageDidLoad()
        XCTAssertNil(model.openArgumentJSON, "a failed checkout must not open an overlay")
    }

    @MainActor
    func testFailToPrepareMarksFailure() {
        let model = PaddleCheckoutModel(plan: .pro, createTransaction: nil)
        model.failToPrepare()
        guard case .failed = model.phase else { return XCTFail("expected failed") }
    }

    // MARK: - HTML harness

    func testHTMLPageEmbedsTokenAndSandboxEnvironment() {
        let html = PaddleCheckoutHTML.page(config: .sandbox)
        XCTAssertTrue(html.contains("cdn.paddle.com/paddle/v2/paddle.js"))
        XCTAssertTrue(html.contains(#"Paddle.Environment.set("sandbox")"#))
        XCTAssertTrue(html.contains("test_7a55409b65e7f906b94b863e63a"))
        XCTAssertTrue(html.contains("window.sentwiseOpenCheckout"))
        XCTAssertTrue(html.contains("messageHandlers.sentwise"))
        // The overlay-open signal the app now relies on to mark "presenting".
        XCTAssertTrue(html.contains("paddle.opened"))
        XCTAssertTrue(html.contains("paddle.errorPayload"))
        XCTAssertTrue(html.contains(#"post("checkout.error", checkoutErrorDetail(data));"#))
    }
}
