import XCTest
@testable import Sentwise

/// Unit tests for `FeedbackMailComposer` — the pre-filled `mailto:` URL that
/// "Report a Problem" opens (item 36).
final class FeedbackMailComposerTests: XCTestCase {

    private func makeURL() -> URL? {
        FeedbackMailComposer.mailtoURL(
            appVersion: "1.4.2",
            buildNumber: "88",
            osVersion: "14.5.0",
            bundleFilename: "Sentwise-Diagnostics-20260826-101500.txt"
        )
    }

    func testAddressesTheDedicatedFeedbackInbox() throws {
        let url = try XCTUnwrap(makeURL())
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:feedback@sentwise.ai"), url.absoluteString)
        XCTAssertEqual(FeedbackMailComposer.feedbackAddress, "feedback@sentwise.ai")
    }

    func testSubjectIsPercentEncodedAndCarriesAppVersion() throws {
        let url = try XCTUnwrap(makeURL())
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let subject = try XCTUnwrap(components.queryItems?.first { $0.name == "subject" }?.value)
        XCTAssertEqual(subject, "Sentwise problem report (v1.4.2)")
        // A raw space would be an encoding bug; the encoded form must not contain one.
        let encoded = try XCTUnwrap(components.percentEncodedQuery)
        XCTAssertFalse(encoded.contains(" "))
        XCTAssertTrue(encoded.contains("subject="))
    }

    func testBodyCarriesAppAndMacOSVersionAndAttachmentInstruction() throws {
        let url = try XCTUnwrap(makeURL())
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(components.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("App version: 1.4.2 (88)"), body)
        XCTAssertTrue(body.contains("macOS: 14.5.0"), body)
        XCTAssertTrue(body.contains("Sentwise-Diagnostics-20260826-101500.txt"), body)
        XCTAssertTrue(body.lowercased().contains("attach"), body)
    }

    func testEncodedQueryHasNoUnescapedSpaces() throws {
        let url = try XCTUnwrap(makeURL())
        // The whole URL must be well-formed with no literal spaces or newlines.
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertFalse(url.absoluteString.contains("\n"))
    }
}
