import XCTest
@testable import Sentwise

/// Unit tests for `DiagnosticsRedactor` — the default-safe scrub applied to
/// every diagnostics bundle before it can leave the app (item 36).
final class DiagnosticsRedactorTests: XCTestCase {

    func testRedactsASingleEmailAddress() {
        let input = "Watcher drafted a reply to marcus@example.com about the call"
        let output = DiagnosticsRedactor.redact(input)
        XCTAssertFalse(output.contains("marcus@example.com"))
        XCTAssertTrue(output.contains(DiagnosticsRedactor.emailPlaceholder))
    }

    func testRedactsEveryEmailAddressInAMultilineBlob() {
        let input = """
        From: alice@company.co.uk
        To: bob.smith+tag@sub.domain.io
        cc: carol@x.org
        """
        let output = DiagnosticsRedactor.redact(input)
        XCTAssertFalse(output.contains("@"), output)
        XCTAssertEqual(
            output.components(separatedBy: DiagnosticsRedactor.emailPlaceholder).count - 1,
            3
        )
    }

    func testRedactsBearerTokens() {
        let input = "authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature"
        let output = DiagnosticsRedactor.redact(input)
        XCTAssertFalse(output.contains("eyJhbGciOiJIUzI1NiJ9.payload.signature"))
        XCTAssertTrue(output.contains(DiagnosticsRedactor.tokenPlaceholder))
    }

    func testRedactsSecretAssignments() {
        let input = "apiKey=sk-live-abc123 password: hunter2 sessionId=SID-9f8e"
        let output = DiagnosticsRedactor.redact(input)
        XCTAssertFalse(output.contains("sk-live-abc123"))
        XCTAssertFalse(output.contains("hunter2"))
        XCTAssertFalse(output.contains("SID-9f8e"))
        // The key names survive so the shape of the log stays readable.
        XCTAssertTrue(output.contains("apiKey"))
        XCTAssertTrue(output.contains("password"))
    }

    func testLeavesNonSensitiveTextIntact() {
        let input = """
        App version: 1.2.3 (45)
        macOS: 14.5.0
        LLM provider: managed
        Poll interval: 300s
        """
        let output = DiagnosticsRedactor.redact(input)
        XCTAssertEqual(output, input)
    }

    func testIsIdempotent() {
        let input = "Contact me@example.com with Bearer abcdef123456"
        let once = DiagnosticsRedactor.redact(input)
        let twice = DiagnosticsRedactor.redact(once)
        XCTAssertEqual(once, twice)
    }
}
