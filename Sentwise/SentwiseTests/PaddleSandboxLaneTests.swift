import XCTest
@testable import Sentwise

/// Item 123 — the client half of the Paddle sandbox lane gate. The app opens the
/// sandbox checkout only when the Worker reports the sandbox lane AND the account
/// is a `@prowlqa.dev` QA account AND the lane is complete; production accounts
/// can never resolve to sandbox prices.
final class PaddleSandboxLaneTests: XCTestCase {

    private let sandboxPrices = ManagedBillingLane.Prices(
        starter: "pri_sbx_starter",
        pro: "pri_sbx_pro",
        unlimited: "pri_sbx_unlimited"
    )

    private func sandboxLane(
        token: String? = "test_sandbox_token",
        prices: ManagedBillingLane.Prices? = nil
    ) -> ManagedBillingLane {
        ManagedBillingLane(environment: "sandbox", clientSideToken: token, prices: prices ?? sandboxPrices)
    }

    // MARK: - QA email

    func testQAEmailAcceptsOnlyTheExactDomain() {
        XCTAssertTrue(PaddleConfig.isQAAccountEmail("qa@prowlqa.dev"))
        XCTAssertTrue(PaddleConfig.isQAAccountEmail(" QA+m3@ProwlQA.dev "))
        for email in [
            "qa@prowlqa.dev.evil.com", "qa@sub.prowlqa.dev", "qa@notprowlqa.dev",
            "@prowlqa.dev", "a@b@prowlqa.dev", "prowlqa.dev", "marcus@example.com", ""
        ] {
            XCTAssertFalse(PaddleConfig.isQAAccountEmail(email), email)
        }
        XCTAssertFalse(PaddleConfig.isQAAccountEmail(nil))
    }

    // MARK: - Gate

    func testQAAccountInSandboxLaneGetsTheServiceSuppliedSandboxConfig() {
        guard let config = PaddleConfig.resolved(billing: sandboxLane(), accountEmail: "qa@prowlqa.dev") else {
            return XCTFail("a complete sandbox lane must resolve")
        }
        XCTAssertEqual(config.environment, .sandbox)
        XCTAssertEqual(config.paddleJSEnvironment, "sandbox")
        XCTAssertEqual(config.clientSideToken, "test_sandbox_token")
        XCTAssertEqual(config.priceID(for: .starter), "pri_sbx_starter")
        XCTAssertEqual(config.priceID(for: .pro), "pri_sbx_pro")
        XCTAssertEqual(config.priceID(for: .unlimited), "pri_sbx_unlimited")
        XCTAssertEqual(config.checkoutOrigin, PaddleConfig.active.checkoutOrigin)
    }

    func testProductionAccountNeverSeesSandboxPricesEvenIfTheServiceSaysSandbox() {
        let config = PaddleConfig.resolved(billing: sandboxLane(), accountEmail: "marcus@example.com")
            ?? PaddleConfig.sandbox
        XCTAssertEqual(config, PaddleConfig.production)
        for plan in PaddlePlan.allCases {
            XCTAssertFalse(config.priceID(for: plan).hasPrefix("pri_sbx_"))
        }
    }

    func testAccountWithoutEmailIsProduction() {
        XCTAssertEqual(PaddleConfig.resolved(billing: sandboxLane(), accountEmail: nil), .production)
    }

    func testQAAccountIsProductionWhenTheServiceSaysProductionOrNothing() {
        XCTAssertEqual(
            PaddleConfig.resolved(
                billing: ManagedBillingLane(environment: "production"),
                accountEmail: "qa@prowlqa.dev"
            ),
            .production
        )
        XCTAssertEqual(PaddleConfig.resolved(billing: nil, accountEmail: "qa@prowlqa.dev"), .production)
        XCTAssertEqual(
            PaddleConfig.resolved(
                billing: ManagedBillingLane(environment: "Sandbox", clientSideToken: "test_x", prices: sandboxPrices),
                accountEmail: "qa@prowlqa.dev"
            ),
            .production
        )
    }

    func testUnavailableSandboxLaneIsNilNotProduction() {
        let unavailable = ManagedBillingLane(environment: "sandbox", checkoutAvailable: false)
        XCTAssertNil(PaddleConfig.resolved(billing: unavailable, accountEmail: "qa@prowlqa.dev"))
        // A production account told "sandbox, unavailable" still just gets production.
        XCTAssertEqual(
            PaddleConfig.resolved(billing: unavailable, accountEmail: "marcus@example.com"),
            .production
        )
        // An explicit available flag with a complete lane is sandbox.
        let available = ManagedBillingLane(
            environment: "sandbox",
            checkoutAvailable: true,
            clientSideToken: "test_x",
            prices: sandboxPrices
        )
        XCTAssertEqual(
            PaddleConfig.resolved(billing: available, accountEmail: "qa@prowlqa.dev")?.environment,
            .sandbox
        )
    }

    func testIncompleteOrSuspiciousSandboxLaneIsUnavailable() {
        let qa = "qa@prowlqa.dev"
        // No token / empty token / a live token.
        XCTAssertNil(PaddleConfig.resolved(billing: sandboxLane(token: nil), accountEmail: qa))
        XCTAssertNil(PaddleConfig.resolved(billing: sandboxLane(token: " "), accountEmail: qa))
        XCTAssertNil(PaddleConfig.resolved(billing: sandboxLane(token: "live_abc"), accountEmail: qa))
        // Missing prices, empty price, duplicate prices, or a live price id.
        XCTAssertNil(
            PaddleConfig.resolved(
                billing: ManagedBillingLane(environment: "sandbox", clientSideToken: "test_x"),
                accountEmail: qa
            )
        )
        XCTAssertNil(
            PaddleConfig.resolved(
                billing: sandboxLane(prices: .init(starter: "", pro: "pri_b", unlimited: "pri_c")),
                accountEmail: qa
            )
        )
        XCTAssertNil(
            PaddleConfig.resolved(
                billing: sandboxLane(prices: .init(starter: "pri_a", pro: "pri_a", unlimited: "pri_c")),
                accountEmail: qa
            )
        )
        XCTAssertNil(
            PaddleConfig.resolved(
                billing: sandboxLane(prices: .init(
                    starter: PaddleConfig.production.priceID(for: .starter),
                    pro: "pri_b",
                    unlimited: "pri_c"
                )),
                accountEmail: qa
            )
        )
    }

    // MARK: - /v1/me decoding

    func testDecodesSandboxBillingLaneFromAccountStatus() throws {
        let json = """
        {"userId":"user_qa","email":"qa@prowlqa.dev",
         "billing":{"environment":"sandbox","checkoutAvailable":true,"clientSideToken":"test_tok",
                    "prices":{"starter":"pri_s","pro":"pri_p","unlimited":"pri_u"}}}
        """
        let status = try JSONDecoder().decode(ManagedAccountStatus.self, from: Data(json.utf8))
        XCTAssertEqual(
            status.billing,
            ManagedBillingLane(
                environment: "sandbox",
                checkoutAvailable: true,
                clientSideToken: "test_tok",
                prices: .init(starter: "pri_s", pro: "pri_p", unlimited: "pri_u")
            )
        )
    }

    func testOlderWorkerWithoutBillingDecodesToNil() throws {
        let json = #"{"userId":"user_1","email":"marcus@example.com"}"#
        let status = try JSONDecoder().decode(ManagedAccountStatus.self, from: Data(json.utf8))
        XCTAssertNil(status.billing)
    }

    func testIncompleteSandboxBlockStillDecodesAsSandboxUnavailable() throws {
        let json = """
        {"userId":"user_qa","email":"qa@prowlqa.dev",
         "billing":{"environment":"sandbox","checkoutAvailable":false,"prices":{}}}
        """
        let status = try JSONDecoder().decode(ManagedAccountStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.billing?.environment, "sandbox")
        XCTAssertEqual(status.billing?.checkoutAvailable, false)
        XCTAssertNil(status.billing?.prices)
        XCTAssertNil(PaddleConfig.resolved(billing: status.billing, accountEmail: status.email))
    }

    func testPartialPricesAndTokenTypeErrorsDoNotLoseTheLane() throws {
        let json = """
        {"userId":"user_qa","email":"qa@prowlqa.dev",
         "billing":{"environment":"sandbox","clientSideToken":7,"prices":{"starter":"pri_s"}}}
        """
        let status = try JSONDecoder().decode(ManagedAccountStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.billing?.environment, "sandbox")
        XCTAssertNil(status.billing?.clientSideToken)
        XCTAssertNil(status.billing?.prices)
        XCTAssertNil(
            PaddleConfig.resolved(billing: status.billing, accountEmail: status.email),
            "an incomplete sandbox lane is unavailable, never production"
        )
    }

    func testMalformedBillingNeverBreaksAccountStatus() throws {
        let json = #"{"userId":"user_1","email":"marcus@example.com","billing":"sandbox"}"#
        let status = try JSONDecoder().decode(ManagedAccountStatus.self, from: Data(json.utf8))
        XCTAssertNil(status.billing)
        XCTAssertEqual(status.userID, "user_1")
    }
}
