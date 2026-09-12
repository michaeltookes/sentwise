import XCTest
@testable import Sentwise

/// Unit tests for `LegalSupportLinks` — the Legal & Support links surfaced in
/// Settings → About (backlog item 72). These lock the exact hosted destinations,
/// the rendered order, and the accessibility identifiers the About pane binds to.
final class LegalSupportLinksTests: XCTestCase {

    func testAllLinksAreOrderedTermsPrivacySecuritySupport() {
        XCTAssertEqual(
            LegalSupportLinks.all,
            [
                LegalSupportLinks.terms,
                LegalSupportLinks.privacy,
                LegalSupportLinks.security,
                LegalSupportLinks.support
            ]
        )
    }

    func testEveryLinkTargetsTheCanonicalSentwiseHost() {
        for item in LegalSupportLinks.all {
            XCTAssertEqual(item.url.scheme, "https", item.id)
            XCTAssertEqual(item.url.host, "sentwise.ai", item.id)
        }
    }

    func testExactDestinationURLs() {
        XCTAssertEqual(LegalSupportLinks.terms.url.absoluteString, "https://sentwise.ai/terms")
        XCTAssertEqual(LegalSupportLinks.privacy.url.absoluteString, "https://sentwise.ai/privacy")
        XCTAssertEqual(LegalSupportLinks.security.url.absoluteString, "https://sentwise.ai/security")
        XCTAssertEqual(LegalSupportLinks.support.url.absoluteString, "https://sentwise.ai/support")
    }

    func testTitles() {
        XCTAssertEqual(LegalSupportLinks.terms.title, "Terms of Service")
        XCTAssertEqual(LegalSupportLinks.privacy.title, "Privacy Policy")
        XCTAssertEqual(LegalSupportLinks.security.title, "Security")
        XCTAssertEqual(LegalSupportLinks.support.title, "Support")
    }

    func testAccessibilityIdentifiersAreStableAndUnique() {
        XCTAssertEqual(LegalSupportLinks.terms.id, "legalLinkTerms")
        XCTAssertEqual(LegalSupportLinks.privacy.id, "legalLinkPrivacy")
        XCTAssertEqual(LegalSupportLinks.security.id, "legalLinkSecurity")
        XCTAssertEqual(LegalSupportLinks.support.id, "legalLinkSupport")

        let ids = LegalSupportLinks.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Accessibility identifiers must be unique")
    }

    func testEveryLinkHasAnAccessibilityLabelAndSymbol() {
        for item in LegalSupportLinks.all {
            XCTAssertFalse(item.accessibilityLabel.isEmpty, item.id)
            XCTAssertFalse(item.systemImage.isEmpty, item.id)
        }
    }
}
