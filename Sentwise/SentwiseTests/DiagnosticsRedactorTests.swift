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

    func testRedactsInternalDomainEmailAddress() {
        let input = "Connected account alice@mailserver routed to bob@intranet"
        let output = DiagnosticsRedactor.redact(input)

        XCTAssertFalse(output.contains("alice@mailserver"), output)
        XCTAssertFalse(output.contains("bob@intranet"), output)
        XCTAssertEqual(
            output.components(separatedBy: DiagnosticsRedactor.emailPlaceholder).count - 1,
            2
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

    func testRedactsQuotedStructuredSecretAssignments() {
        let input = #"""
        {"access_token":"eyJ.header.payload","note":"safe"}
        {\"refresh_token\":\"refresh secret value\"}
        password="correct horse battery staple"
        api_key='sk live with spaces'
        """#
        let output = DiagnosticsRedactor.redact(input)

        XCTAssertFalse(output.contains("eyJ.header.payload"), output)
        XCTAssertFalse(output.contains("refresh secret value"), output)
        XCTAssertFalse(output.contains("correct horse battery staple"), output)
        XCTAssertFalse(output.contains("sk live with spaces"), output)
        XCTAssertTrue(output.contains("\"note\":\"safe\""), output)
        XCTAssertEqual(
            output.components(separatedBy: DiagnosticsRedactor.tokenPlaceholder).count - 1,
            4
        )
    }

    func testRedactsCompoundCredentialKeyNames() {
        let input = #"""
        client_secret=client-secret-value
        clientSecret=camel-secret-value
        aws_secret_access_key=aws-secret-access-value
        private_key="BEGIN PRIVATE KEY"
        db_password=database-password
        """#
        let output = DiagnosticsRedactor.redact(input)

        XCTAssertFalse(output.contains("client-secret-value"), output)
        XCTAssertFalse(output.contains("camel-secret-value"), output)
        XCTAssertFalse(output.contains("aws-secret-access-value"), output)
        XCTAssertFalse(output.contains("BEGIN PRIVATE KEY"), output)
        XCTAssertFalse(output.contains("database-password"), output)
        XCTAssertEqual(
            output.components(separatedBy: DiagnosticsRedactor.tokenPlaceholder).count - 1,
            5
        )
    }

    func testRedactsWatchedFolderPathsWithSpaces() {
        let input = """
        Transcript file not readable yet; will retry on a later scan: /Users/priya/Documents/Zoom/2026-08-26 Discovery Call.vtt
        Watched transcript delivery exhausted retry budget: /Users/priya/Documents/Calls/acme pricing follow-up.md
        """
        let output = DiagnosticsRedactor.redact(input)
        XCTAssertFalse(output.contains("/Users/priya"), output)
        XCTAssertFalse(output.contains("Discovery Call.vtt"), output)
        XCTAssertFalse(output.contains("acme pricing follow-up.md"), output)
        XCTAssertEqual(
            output.components(separatedBy: DiagnosticsRedactor.pathPlaceholder).count - 1,
            2
        )
    }

    func testRedactsQuotedAndLabeledPaths() {
        let input = #"path=/Users/priya/Documents/call.vtt file: "/private/tmp/Sentwise-Diagnostics.txt""#
        let output = DiagnosticsRedactor.redact(input)
        XCTAssertFalse(output.contains("/Users/priya"), output)
        XCTAssertFalse(output.contains("/private/tmp"), output)
        XCTAssertTrue(output.contains("path=\(DiagnosticsRedactor.pathPlaceholder)"))
        XCTAssertTrue(output.contains(#"file: ""# + DiagnosticsRedactor.pathPlaceholder))
    }

    func testRedactsAbsolutePathsOutsideCommonRoots() {
        let input = """
        Watched transcript delivery exhausted retry budget: /Network/Meetings/team call.vtt
        path=/data/transcripts/customer-alpha.md
        seenKey=/mnt/custom-share/call.txt
        Help URL: https://sentwise.ai/docs
        """
        let output = DiagnosticsRedactor.redact(input)
        XCTAssertFalse(output.contains("/Network/Meetings"), output)
        XCTAssertFalse(output.contains("/data/transcripts"), output)
        XCTAssertFalse(output.contains("/mnt/custom-share"), output)
        XCTAssertTrue(output.contains("https://sentwise.ai/docs"), output)
        XCTAssertEqual(
            output.components(separatedBy: DiagnosticsRedactor.pathPlaceholder).count - 1,
            3
        )
    }

    func testRedactsFullUnlabeledPathsWithSpaces() {
        let input = "Could not open /Volumes/Client Calls/customer interview.vtt"
        let output = DiagnosticsRedactor.redact(input)

        XCTAssertFalse(output.contains("/Volumes"), output)
        XCTAssertFalse(output.contains("Client Calls"), output)
        XCTAssertFalse(output.contains("customer interview.vtt"), output)
        XCTAssertEqual(output, "Could not open \(DiagnosticsRedactor.pathPlaceholder)")
    }

    func testRedactsFilesystemURLs() {
        let input = """
        source=file:///Users/priya/Client/meeting.vtt
        url=file:///Volumes/Client%20Calls/customer%20interview.vtt
        Help URL: https://sentwise.ai/docs
        """
        let output = DiagnosticsRedactor.redact(input)

        XCTAssertFalse(output.contains("file:///Users/priya"), output)
        XCTAssertFalse(output.contains("file:///Volumes/Client%20Calls"), output)
        XCTAssertTrue(output.contains("https://sentwise.ai/docs"), output)
        XCTAssertEqual(
            output.components(separatedBy: DiagnosticsRedactor.pathPlaceholder).count - 1,
            2
        )
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
