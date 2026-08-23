import XCTest
@testable import Sentwise

/// Tests for classifying the model's output as a ready reply or a "needs input"
/// flag (item 13). Misclassifying either way is the failure mode: a fabricated
/// reply presented as ready, or a real reply hidden behind a false flag.
final class DraftOutcomeTests: XCTestCase {

    func testPlainReplyIsReady() throws {
        let outcome = try DraftGenerator.parseOutcome("Sure, Tuesday at 3pm works for me.")
        XCTAssertEqual(outcome, .ready("Sure, Tuesday at 3pm works for me."))
    }

    func testReadyReplyStillStripsLeadingSubjectLine() throws {
        let outcome = try DraftGenerator.parseOutcome("Subject: Re: Hi\n\nThanks — got it.")
        XCTAssertEqual(outcome, .ready("Thanks — got it."))
    }

    func testEmptyOutputThrows() {
        XCTAssertThrowsError(try DraftGenerator.parseOutcome("   \n\n")) { error in
            XCTAssertEqual(error as? DraftError, .emptyDraft)
        }
    }

    // MARK: - Needs-info flagging

    func testSentinelFlagsNeedsInfoWithSummaryAndMissingItems() throws {
        let text = """
        NEEDS_INFO: I can't confirm the meeting without the details only you have.
        - The date and time you want to propose
        - Whether the Zoom link should be reused
        """
        let outcome = try DraftGenerator.parseOutcome(text)
        guard case .needsInfo(let info) = outcome else {
            return XCTFail("expected needsInfo, got \(outcome)")
        }
        XCTAssertEqual(info.summary, "I can't confirm the meeting without the details only you have.")
        XCTAssertEqual(info.missing, [
            "The date and time you want to propose",
            "Whether the Zoom link should be reused"
        ])
    }

    func testSentinelIsCaseInsensitiveAndToleratesLeadingBlankLines() throws {
        let outcome = try DraftGenerator.parseOutcome("\n\nneeds_info: Need the invoice number.")
        guard case .needsInfo(let info) = outcome else {
            return XCTFail("expected needsInfo, got \(outcome)")
        }
        XCTAssertEqual(info.summary, "Need the invoice number.")
        XCTAssertTrue(info.missing.isEmpty)
    }

    func testNotReplyWorthySentinelIsDedicatedOutcome() throws {
        let outcome = try DraftGenerator.parseOutcome("\n\nnot_reply_worthy: This is an automated receipt.")
        guard case .notReplyWorthy(let verdict) = outcome else {
            return XCTFail("expected notReplyWorthy, got \(outcome)")
        }
        XCTAssertEqual(verdict.summary, "This is an automated receipt.")
    }

    func testSentinelAfterLeadingSubjectLineFlagsNeedsInfo() throws {
        let text = """
        Subject: Re: Budget

        NEEDS_INFO: I can't approve this without the figure only you have.
        - The approved budget amount
        """

        let outcome = try DraftGenerator.parseOutcome(text)
        guard case .needsInfo(let info) = outcome else {
            return XCTFail("expected needsInfo, got \(outcome)")
        }
        XCTAssertEqual(info.summary, "I can't approve this without the figure only you have.")
        XCTAssertEqual(info.missing, ["The approved budget amount"])
    }

    func testAsteriskBulletsAreAlsoParsedAsMissingItems() throws {
        let outcome = try DraftGenerator.parseOutcome("NEEDS_INFO: Missing details.\n* The budget cap\n* The deadline")
        guard case .needsInfo(let info) = outcome else {
            return XCTFail("expected needsInfo, got \(outcome)")
        }
        XCTAssertEqual(info.missing, ["The budget cap", "The deadline"])
    }

    func testSentinelWithNoSummaryGetsAReadableFallback() throws {
        let outcome = try DraftGenerator.parseOutcome("NEEDS_INFO:")
        guard case .needsInfo(let info) = outcome else {
            return XCTFail("expected needsInfo, got \(outcome)")
        }
        XCTAssertFalse(info.summary.isEmpty, "a flagged draft must always explain itself")
    }

    /// The sentinel only counts as the first non-empty line. A normal reply that
    /// merely mentions the phrase must not be misread as a flag.
    func testSentinelMidReplyDoesNotFalselyFlag() throws {
        let text = "Happy to help. Let me know if the team needs_info: on the rollout."
        let outcome = try DraftGenerator.parseOutcome(text)
        guard case .ready = outcome else {
            return XCTFail("a mid-body mention must not flag the draft, got \(outcome)")
        }
    }
}
