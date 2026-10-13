import XCTest
@testable import Sentwise

/// Build configuration resolution (item 123): production builds resolve to the
/// production values with no Info.plist keys, a QA build's keys resolve to the
/// sandbox, and a partial or malformed QA config makes checkout unavailable,
/// never production prices.
final class BuildConfigurationTests: XCTestCase {

    private typealias Key = BuildConfiguration.InfoKey

    private func urlTypes(_ scheme: String) -> [[String: Any]] {
        [["CFBundleURLName": "com.tookes.Sentwise", "CFBundleURLSchemes": [scheme]]]
    }

    private func qaInfo(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var info: [String: Any] = [
            Key.serviceBaseURL: "https://sentwise-inference-sandbox.sentwise-service.workers.dev",
            Key.clerkFrontendAPIURL: "https://example-dev.clerk.accounts.dev",
            Key.paddleEnvironment: "sandbox",
            Key.paddleClientToken: "test_qa_token",
            Key.paddleStarterPriceID: "pri_qa_starter",
            Key.paddleProPriceID: "pri_qa_pro",
            Key.paddleUnlimitedPriceID: "pri_qa_unlimited",
            Key.keychainServiceSuffix: ".qa",
            Key.appSupportDirectoryName: "Sentwise QA",
            Key.displayName: "Sentwise QA",
            Key.bundleIdentifier: "com.tookes.Sentwise.qa",
            Key.urlTypes: urlTypes("sentwise-qa")
        ]
        for (key, value) in overrides { info[key] = value }
        return info
    }

    // MARK: - Production

    private func assertProduction(_ config: BuildConfiguration, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(config.isProduction, file: file, line: line)
        XCTAssertEqual(config.serviceBaseURL.absoluteString,
                       "https://sentwise-inference.sentwise-service.workers.dev", file: file, line: line)
        XCTAssertEqual(config.clerkFrontendAPIBaseURL.absoluteString, "https://clerk.sentwise.ai", file: file, line: line)
        XCTAssertEqual(config.keychainServiceSuffix, "", file: file, line: line)
        XCTAssertEqual(config.appSupportDirectoryName, "Sentwise", file: file, line: line)
        XCTAssertEqual(config.urlScheme, "sentwise", file: file, line: line)
        XCTAssertEqual(config.appDisplayName, "Sentwise", file: file, line: line)
        XCTAssertEqual(config.bundleIdentifier, "com.tookes.Sentwise", file: file, line: line)
        XCTAssertEqual(config.paddle, .production, file: file, line: line)
        XCTAssertTrue(config.allowsAutomaticUpdates, file: file, line: line)
    }

    func testNoInfoDictionaryResolvesToProduction() {
        assertProduction(BuildConfiguration.resolve(infoDictionary: nil))
    }

    func testProductionPlistWithoutKeysResolvesToProduction() {
        assertProduction(BuildConfiguration.resolve(infoDictionary: [Key.urlTypes: urlTypes("sentwise")]))
    }

    func testEmptyOrUnexpandedKeysResolveToProduction() {
        var info: [String: Any] = [Key.urlTypes: urlTypes("sentwise")]
        for key in Key.overrides { info[key] = "" }
        assertProduction(BuildConfiguration.resolve(infoDictionary: info))
        for key in Key.overrides { info[key] = "  " }
        info[Key.serviceBaseURL] = "$(SENTWISE_SERVICE_BASE_URL)"
        assertProduction(BuildConfiguration.resolve(infoDictionary: info))
    }

    func testTheRunningTestHostIsAProductionBuild() {
        assertProduction(BuildConfiguration.current)
        XCTAssertEqual(KeychainStore.appService, KeychainStore.productionService)
        XCTAssertEqual(SentwiseURLCallback.scheme, "sentwise")
        XCTAssertEqual(PaddleConfig.active, .production)
    }

    // MARK: - QA

    func testCompleteQAConfigResolvesToTheSandbox() throws {
        let config = BuildConfiguration.resolve(infoDictionary: qaInfo())
        XCTAssertFalse(config.isProduction)
        XCTAssertEqual(config.serviceBaseURL.absoluteString,
                       "https://sentwise-inference-sandbox.sentwise-service.workers.dev")
        XCTAssertEqual(config.clerkFrontendAPIBaseURL.absoluteString, "https://example-dev.clerk.accounts.dev")
        XCTAssertEqual(config.keychainServiceSuffix, ".qa")
        XCTAssertEqual(config.appSupportDirectoryName, "Sentwise QA")
        XCTAssertNotEqual(config.appSupportDirectoryName, BuildConfiguration.Production.appSupportDirectoryName)
        XCTAssertEqual(config.urlScheme, "sentwise-qa")
        XCTAssertEqual(config.appDisplayName, "Sentwise QA")
        XCTAssertEqual(config.bundleIdentifier, "com.tookes.Sentwise.qa")
        XCTAssertFalse(config.allowsAutomaticUpdates)

        let paddle = try XCTUnwrap(config.paddle)
        XCTAssertEqual(paddle.environment, .sandbox)
        XCTAssertEqual(paddle.paddleJSEnvironment, "sandbox")
        XCTAssertEqual(paddle.clientSideToken, "test_qa_token")
        XCTAssertEqual(paddle.priceID(for: .starter), "pri_qa_starter")
        XCTAssertEqual(paddle.priceID(for: .pro), "pri_qa_pro")
        XCTAssertEqual(paddle.priceID(for: .unlimited), "pri_qa_unlimited")
        XCTAssertTrue(PaddleCheckoutHTML.page(config: paddle).contains(#"Paddle.Environment.set("sandbox");"#))
    }

    func testPartialOrMalformedPaddleConfigMakesCheckoutUnavailable() {
        let liveStarter = PaddleConfig.production.priceID(for: .starter)
        let cases: [(String, [String: Any])] = [
            ("missing price", [Key.paddleUnlimitedPriceID: ""]),
            ("missing token", [Key.paddleClientToken: ""]),
            ("missing environment", [Key.paddleEnvironment: ""]),
            ("production environment", [Key.paddleEnvironment: "production"]),
            ("live token", [Key.paddleClientToken: "live_3affc7e38f8efd6ebd94616ab39"]),
            ("production price id", [Key.paddleStarterPriceID: liveStarter]),
            ("duplicate price ids", [Key.paddleProPriceID: "pri_qa_starter"]),
            ("not a price id", [Key.paddleProPriceID: "qa_pro"]),
            ("missing service URL", [Key.serviceBaseURL: ""]),
            ("malformed service URL", [Key.serviceBaseURL: "not a url"]),
            ("plain-http service URL", [Key.serviceBaseURL: "http://sentwise-inference-sandbox.example"]),
            ("production service URL", [Key.serviceBaseURL: "https://sentwise-inference.sentwise-service.workers.dev"]),
            ("missing Clerk URL", [Key.clerkFrontendAPIURL: ""]),
            ("production Clerk URL", [Key.clerkFrontendAPIURL: "https://clerk.sentwise.ai"])
        ]
        for (name, overrides) in cases {
            let config = BuildConfiguration.resolve(infoDictionary: qaInfo(overrides))
            XCTAssertFalse(config.isProduction, name)
            XCTAssertNil(config.paddle, name)
            XCTAssertFalse(config.allowsAutomaticUpdates, name)
        }
    }

    func testOnlyPaddleKeysPresentStillNeverUsesProductionPrices() {
        let config = BuildConfiguration.resolve(infoDictionary: [
            Key.paddleEnvironment: "sandbox",
            Key.paddleClientToken: "test_qa_token"
        ])
        XCTAssertFalse(config.isProduction)
        XCTAssertNil(config.paddle)
        XCTAssertEqual(config.keychainServiceSuffix, ".qa")
        XCTAssertEqual(config.appSupportDirectoryName, "Sentwise QA")
    }

    func testMalformedQAKeychainSuffixAndDirectoryNeverFallBackToProduction() {
        for suffix in ["", "qa", "./x", ".a b", "." + String(repeating: "x", count: 40)] {
            let config = BuildConfiguration.resolve(infoDictionary: qaInfo([Key.keychainServiceSuffix: suffix]))
            XCTAssertEqual(config.keychainServiceSuffix, ".qa", suffix)
        }
        for name in ["", "Sentwise", "sentwise", "../Sentwise", "a/b", ".hidden"] {
            let config = BuildConfiguration.resolve(infoDictionary: qaInfo([Key.appSupportDirectoryName: name]))
            XCTAssertEqual(config.appSupportDirectoryName, "Sentwise QA", name)
        }
    }

    func testQAClerkURLResolvesToTheDevelopmentInstance() {
        let config = BuildConfiguration.resolve(infoDictionary: qaInfo())
        XCTAssertTrue(config.isSignInAvailable)
        XCTAssertEqual(config.clerkFrontendAPIBaseURL.host, "example-dev.clerk.accounts.dev")
        XCTAssertTrue(BuildConfiguration.resolve(infoDictionary: nil).isSignInAvailable)
    }

    func testMalformedOrProductionQAClerkURLMakesSignInUnavailableNeverProduction() {
        for value in ["", "not a url", "http://example-dev.clerk.accounts.dev",
                      "https://clerk.sentwise.ai", "https://CLERK.sentwise.ai/"] {
            let config = BuildConfiguration.resolve(infoDictionary: qaInfo([Key.clerkFrontendAPIURL: value]))
            XCTAssertFalse(config.isSignInAvailable, value)
            XCTAssertEqual(config.clerkFrontendAPIBaseURL, BuildConfiguration.NonProductionFallback.clerkFrontendAPIURL, value)
            XCTAssertNotEqual(config.clerkFrontendAPIBaseURL.host, "clerk.sentwise.ai", value)
            XCTAssertNil(config.paddle, value)
        }
    }

    func testMalformedOrProductionQAServiceURLNeverPointsAtProduction() {
        for value in ["", "not a url", "https://sentwise-inference.sentwise-service.workers.dev"] {
            let config = BuildConfiguration.resolve(infoDictionary: qaInfo([Key.serviceBaseURL: value]))
            XCTAssertEqual(config.serviceBaseURL, BuildConfiguration.NonProductionFallback.serviceBaseURL, value)
        }
    }

    func testClerkClientRefusesTheUnavailableInstanceWithoutANetworkCall() async {
        let client = ClerkClient(frontendAPIBaseURL: BuildConfiguration.NonProductionFallback.clerkFrontendAPIURL)
        do {
            _ = try await client.revokeSession(sessionId: "sess_1", clientToken: "token")
            XCTFail("expected sign-in to be unavailable")
        } catch {
            XCTAssertEqual(error as? ClerkError, .transport("Sign-in isn't available in this build."))
        }
    }

    func testQABundleIdentifierNeverResolvesToProduction() {
        for value in ["", "com.tookes.Sentwise", "com.example.Other", "com.tookes.Sentwise.a b"] {
            let config = BuildConfiguration.resolve(infoDictionary: qaInfo([Key.bundleIdentifier: value]))
            XCTAssertEqual(config.bundleIdentifier, "com.tookes.Sentwise.qa", value)
        }
        XCTAssertEqual(DiagnosticLog.subsystem, "com.tookes.Sentwise")
    }

    func testURLSchemeIsTheOneTheBuildDeclares() {
        XCTAssertEqual(BuildConfiguration.resolve(infoDictionary: qaInfo()).urlScheme, "sentwise-qa")
        let malformed = qaInfo([Key.urlTypes: urlTypes("1 bad")])
        XCTAssertEqual(BuildConfiguration.resolve(infoDictionary: malformed).urlScheme, "sentwise")
    }

    // MARK: - Consumers

    func testCallbackParserAcceptsOnlyTheBuildScheme() throws {
        let qaURL = try XCTUnwrap(URL(string: "sentwise-qa://oauth-callback?rotating_token_nonce=n1&state=s1"))
        let prodURL = try XCTUnwrap(URL(string: "sentwise://oauth-callback?rotating_token_nonce=n1&state=s1"))
        XCTAssertEqual(SentwiseURLCallback(url: qaURL, scheme: "sentwise-qa"), .managedOAuth(nonce: "n1", flowID: "s1"))
        XCTAssertNil(SentwiseURLCallback(url: prodURL, scheme: "sentwise-qa"))
        XCTAssertNil(SentwiseURLCallback(url: qaURL, scheme: "sentwise"))
        XCTAssertEqual(SentwiseURLCallback(url: prodURL), .managedOAuth(nonce: "n1", flowID: "s1"))
    }

    func testClerkClientDefaultsToTheBuildsFrontendAPI() {
        XCTAssertEqual(ClerkClient().frontendAPIBaseURL, BuildConfiguration.current.clerkFrontendAPIBaseURL)
    }
}
