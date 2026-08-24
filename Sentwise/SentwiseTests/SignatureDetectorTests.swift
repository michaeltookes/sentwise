import XCTest
@testable import Sentwise

/// Unit tests for `SignatureDetector` — the heuristic that extracts a recurring
/// signature block from a sample of Sent messages (item 24).
final class SignatureDetectorTests: XCTestCase {

    // MARK: - Positive detection

    func testDetectsRecurringSignOffBlockAcrossMessages() {
        let sig = "Best,\nJane Doe\nAcme Corp"
        let bodies = [
            "Hi Bob,\n\nSounds good, let's meet Tuesday.\n\n\(sig)",
            "Hello Sam,\n\nHere are the numbers you asked for.\n\n\(sig)"
        ]
        let detected = SignatureDetector.detect(fromSentBodies: bodies)
        XCTAssertEqual(detected, sig)
    }

    func testDetectsBlockAfterStandardDelimiter() {
        let bodies = [
            "Thanks for the note.\n\n-- \nJane Doe\njane@acme.com\n555-1212",
            "Will do.\n\n-- \nJane Doe\njane@acme.com\n555-1212"
        ]
        let detected = SignatureDetector.detect(fromSentBodies: bodies)
        XCTAssertEqual(detected, "Jane Doe\njane@acme.com\n555-1212")
    }

    func testChoosesMostCommonSignatureAmongVariants() {
        let common = "Regards,\nJane"
        let bodies = [
            "One.\n\n\(common)",
            "Two.\n\n\(common)",
            "Three.\n\nCheers,\nJ"
        ]
        let detected = SignatureDetector.detect(fromSentBodies: bodies)
        XCTAssertEqual(detected, common)
    }

    func testSingleSampleWithSignOffIsAccepted() {
        // With only one usable sample there's nothing to corroborate against, so a
        // sign-off-anchored candidate is accepted on its own.
        let bodies = ["Talk soon,\nJane Doe"]
        let detected = SignatureDetector.detect(fromSentBodies: bodies)
        XCTAssertEqual(detected, "Talk soon,\nJane Doe")
    }

    func testSingleCandidateAcrossMultipleUsableBodiesRequiresCorroboration() {
        let bodies = [
            "Sure, let's meet Tuesday.\n\nBest,\nJane Doe",
            "I'll send the deck after lunch.",
            "Looping in Sam now."
        ]
        XCTAssertNil(SignatureDetector.detect(fromSentBodies: bodies))
    }

    func testDetectionIgnoresQuotedReplyHistory() {
        // The recurring signature is in the fresh text; the quoted history below it
        // (different in each message) must not defeat the match.
        let sig = "Thanks,\nJane"
        let bodies = [
            "Sure thing.\n\n\(sig)\n\nOn Mon, Bob wrote:\n> please advise",
            "Yes.\n\n\(sig)\n\nOn Tue, Sam wrote:\n> any update?"
        ]
        let detected = SignatureDetector.detect(fromSentBodies: bodies)
        XCTAssertEqual(detected, sig)
    }

    // MARK: - Negative detection

    func testReturnsNilWhenNoConsistentSignatureExists() {
        let bodies = [
            "Cheers,\nAlice",
            "Best,\nBob",
            "Regards,\nCarol"
        ]
        XCTAssertNil(SignatureDetector.detect(fromSentBodies: bodies))
    }

    func testReturnsNilWhenRepeatedSignatureCandidatesTie() {
        let desktop = "Best,\nJane Doe\nAcme Corp"
        let mobile = "Thanks,\nJane"
        let bodies = [
            "One.\n\n\(desktop)",
            "Two.\n\n\(desktop)",
            "Three.\n\n\(mobile)",
            "Four.\n\n\(mobile)"
        ]
        XCTAssertNil(SignatureDetector.detect(fromSentBodies: bodies))
    }

    func testReturnsNilWhenNoSignOffOrDelimiter() {
        let bodies = [
            "Hi Bob, sounds good see you then.",
            "Hello Sam, here are the numbers."
        ]
        XCTAssertNil(SignatureDetector.detect(fromSentBodies: bodies))
    }

    func testReturnsNilForEmptyInput() {
        XCTAssertNil(SignatureDetector.detect(fromSentBodies: []))
        XCTAssertNil(SignatureDetector.detect(fromSentBodies: ["", "   ", "\n\n"]))
    }

    func testMidBodySignOffIsNotCapturedAsSignature() {
        // "Thanks" near the top, followed by many non-signature content lines, is
        // outside the trailing window and must not be picked up.
        let filler = (1...9).map { "Line \($0) of ongoing content here." }.joined(separator: "\n")
        let bodies = [
            "Thanks for reaching out.\n\(filler)",
            "Thanks for reaching out.\n\(filler)"
        ]
        XCTAssertNil(SignatureDetector.detect(fromSentBodies: bodies))
    }

    // MARK: - Candidate helpers

    func testSignOffRecognitionStripsTrailingPunctuation() {
        XCTAssertTrue(SignatureDetector.isSignOff("Best,"))
        XCTAssertTrue(SignatureDetector.isSignOff("Thanks!"))
        XCTAssertTrue(SignatureDetector.isSignOff("  Regards  "))
        XCTAssertFalse(SignatureDetector.isSignOff("Best, Jane"))
        XCTAssertFalse(SignatureDetector.isSignOff("See you there"))
    }

    func testSignatureCandidateReturnsNilForPlainBody() {
        XCTAssertNil(SignatureDetector.signatureCandidate("Just a plain message with no closing"))
    }
}
