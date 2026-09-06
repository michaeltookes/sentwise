import XCTest
@testable import Sentwise

/// Checkout wiring for item 56c: price-id routing, the `Paddle.Checkout.open`
/// argument shape (including the Clerk-user-id `customData` the webhook maps by),
/// bridge-event mapping, and the checkout view-model's phase machine — all
/// exercised without a live Paddle overlay.
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

    // MARK: - Checkout request JSON

    func testArgumentJSONCarriesPriceClerkIDAndEmail() throws {
        let request = PaddleCheckoutRequest(
            priceID: "pri_test",
            clerkUserID: "user_123",
            email: "marcus@example.com"
        )
        let json = try request.makeArgumentJSONString()
        XCTAssertTrue(json.contains("\"priceId\":\"pri_test\""), json)
        XCTAssertTrue(json.contains("\"quantity\":1"), json)
        XCTAssertTrue(json.contains("\"clerkUserId\":\"user_123\""), json)
        XCTAssertTrue(json.contains("\"email\":\"marcus@example.com\""), json)
    }

    func testArgumentJSONOmitsCustomerWhenEmailMissing() throws {
        let request = PaddleCheckoutRequest(priceID: "pri_test", clerkUserID: "user_1", email: nil)
        let json = try request.makeArgumentJSONString()
        XCTAssertFalse(json.contains("customer"), json)
        // customData is required (>= one key) — always present.
        XCTAssertTrue(json.contains("\"customData\":{\"clerkUserId\":\"user_1\"}"), json)
    }

    func testArgumentJSONTreatsBlankEmailAsMissing() throws {
        let request = PaddleCheckoutRequest(priceID: "pri_test", clerkUserID: "user_1", email: "   ")
        let json = try request.makeArgumentJSONString()
        XCTAssertFalse(json.contains("customer"), json)
    }

    // MARK: - Bridge-event mapping

    func testBridgeEventMapping() {
        XCTAssertEqual(PaddleBridgeEvent.make(name: "checkout.completed"), .completed)
        XCTAssertEqual(PaddleBridgeEvent.make(name: "checkout.closed"), .closed)
        XCTAssertEqual(PaddleBridgeEvent.make(name: "paddle.ready"), .ready)
        XCTAssertEqual(PaddleBridgeEvent.make(name: "checkout.loaded"), .ready)
        XCTAssertEqual(PaddleBridgeEvent.make(name: "checkout.warning"), .ignored("checkout.warning"))
        if case .failed = PaddleBridgeEvent.make(name: "checkout.error", detail: "card declined") {} else {
            XCTFail("checkout.error should map to .failed")
        }
    }

    func testBridgeErrorWithoutDetailStillHasUserSafeMessage() {
        guard case .failed(let message) = PaddleBridgeEvent.make(name: "paddle.failed") else {
            return XCTFail("expected .failed")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - View-model phase machine

    @MainActor
    func testModelRoutesPriceForPlan() {
        let model = PaddleCheckoutModel(plan: .unlimited, clerkUserID: "user_1", email: nil)
        XCTAssertEqual(model.priceID, PaddleConfig.active.priceID(for: .unlimited))
    }

    @MainActor
    func testModelRefusesCheckoutWithoutClerkID() {
        let model = PaddleCheckoutModel(plan: .pro, clerkUserID: nil, email: "a@b.com")
        XCTAssertFalse(model.canOpenCheckout)
        XCTAssertNil(model.makeCheckoutRequest())
    }

    @MainActor
    func testModelBuildsRequestWithClerkID() {
        let model = PaddleCheckoutModel(plan: .starter, clerkUserID: "  user_9  ", email: "a@b.com")
        let request = model.makeCheckoutRequest()
        XCTAssertEqual(request?.clerkUserID, "user_9")
        XCTAssertEqual(request?.priceID, PaddleConfig.active.priceID(for: .starter))
    }

    @MainActor
    func testReadyThenCompletedTransitions() {
        let model = PaddleCheckoutModel(plan: .pro, clerkUserID: "user_1", email: nil)
        XCTAssertEqual(model.phase, .initializing)
        model.handle(.ready)
        XCTAssertEqual(model.phase, .presenting)
        model.handle(.completed)
        XCTAssertEqual(model.phase, .completed)
    }

    @MainActor
    func testCloseAfterCompletionIsIgnored() {
        let model = PaddleCheckoutModel(plan: .pro, clerkUserID: "user_1", email: nil)
        model.handle(.completed)
        model.handle(.closed)
        XCTAssertEqual(model.phase, .completed, "a close after completion must not overwrite the win")
    }

    @MainActor
    func testCloseWithoutCompletionTransitionsToClosed() {
        let model = PaddleCheckoutModel(plan: .pro, clerkUserID: "user_1", email: nil)
        model.handle(.ready)
        model.handle(.closed)
        XCTAssertEqual(model.phase, .closed)
    }

    @MainActor
    func testFailedTransitionAndTerminalStickiness() {
        let model = PaddleCheckoutModel(plan: .pro, clerkUserID: "user_1", email: nil)
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
    func testFailToPrepareMarksFailure() {
        let model = PaddleCheckoutModel(plan: .pro, clerkUserID: nil, email: nil)
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
    }
}
