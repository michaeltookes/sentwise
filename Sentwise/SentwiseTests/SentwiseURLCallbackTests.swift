import XCTest
@testable import Sentwise

/// Unit tests for the `sentwise://` deep-link parser (item 59): the Clerk-OAuth
/// and OpenRouter callbacks parse, and everything malformed or foreign is rejected.
final class SentwiseURLCallbackTests: XCTestCase {

    private func parse(_ string: String) -> SentwiseURLCallback? {
        guard let url = URL(string: string) else { return nil }
        return SentwiseURLCallback(url: url)
    }

    func testManagedOAuthCallbackParses() {
        XCTAssertEqual(
            parse("sentwise://oauth-callback?rotating_token_nonce=abc123"),
            .managedOAuth(nonce: "abc123")
        )
    }

    func testOpenRouterCallbackParses() {
        XCTAssertEqual(
            parse("sentwise://openrouter-callback?code=xyz789"),
            .openRouter(code: "xyz789")
        )
    }

    func testManagedOAuthIgnoresExtraParams() {
        XCTAssertEqual(
            parse("sentwise://oauth-callback?rotating_token_nonce=abc&state=z"),
            .managedOAuth(nonce: "abc")
        )
    }

    func testForeignSchemeRejected() {
        XCTAssertNil(parse("https://oauth-callback?rotating_token_nonce=abc"))
        XCTAssertNil(parse("myapp://oauth-callback?rotating_token_nonce=abc"))
    }

    func testUnknownHostRejected() {
        XCTAssertNil(parse("sentwise://evil-callback?rotating_token_nonce=abc"))
        XCTAssertNil(parse("sentwise://oauth?rotating_token_nonce=abc"))
    }

    func testMissingRequiredParamRejected() {
        XCTAssertNil(parse("sentwise://oauth-callback?foo=bar"))
        XCTAssertNil(parse("sentwise://openrouter-callback"))
    }

    func testEmptyParamRejected() {
        XCTAssertNil(parse("sentwise://oauth-callback?rotating_token_nonce="))
        XCTAssertNil(parse("sentwise://openrouter-callback?code="))
    }

    func testWrongParamOnRightHostRejected() {
        // OpenRouter host carrying a nonce (not a code) must not cross the wires.
        XCTAssertNil(parse("sentwise://openrouter-callback?rotating_token_nonce=abc"))
        // OAuth host carrying a code (not a nonce) likewise.
        XCTAssertNil(parse("sentwise://oauth-callback?code=abc"))
    }

    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(
            parse("SENTWISE://OAUTH-CALLBACK?rotating_token_nonce=abc"),
            .managedOAuth(nonce: "abc")
        )
    }
}
