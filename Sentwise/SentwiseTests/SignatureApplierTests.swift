import XCTest
@testable import Sentwise

/// Unit tests for `SignatureApplier` — the dedup + placement logic that applies
/// the configured signature to a draft body without dropping or duplicating it
/// (item 24).
final class SignatureApplierTests: XCTestCase {

    private let sig = "Best,\nJane Doe\nAcme Corp"

    // MARK: - Policy: none

    func testNonePolicyLeavesBodyUnchanged() {
        let body = "Sounds good, see you then."
        XCTAssertEqual(SignatureApplier.apply(policy: .none, signature: sig, to: body), body)
    }

    func testNonePolicyDoesNotStripModelSignature() {
        let body = "Sounds good.\n\nCheers,\nJane"
        XCTAssertEqual(SignatureApplier.apply(policy: .none, signature: sig, to: body), body)
    }

    // MARK: - Policy: custom — appending

    func testCustomAppendsSignatureWhenMissing() {
        let body = "Sounds good, see you Tuesday."
        let result = SignatureApplier.apply(policy: .custom, signature: sig, to: body)
        XCTAssertEqual(result, "Sounds good, see you Tuesday.\n\n\(sig)")
    }

    func testCustomAppendsWithExactlyOneBlankLineGap() {
        let body = "Reply text.\n\n\n"
        let result = SignatureApplier.apply(policy: .custom, signature: sig, to: body)
        XCTAssertEqual(result, "Reply text.\n\n\(sig)")
    }

    // MARK: - Policy: custom — dedup

    func testCustomDoesNotDuplicateConfiguredSignature() {
        let body = "Sounds good.\n\n\(sig)"
        let result = SignatureApplier.apply(policy: .custom, signature: sig, to: body)
        XCTAssertEqual(result, body)
    }

    func testCustomDoesNotDoubleUpWhenModelWroteDifferentSignature() {
        // The model emitted its own closing; a second signature must not be added.
        let body = "Sounds good.\n\nThanks,\nJane"
        let result = SignatureApplier.apply(policy: .custom, signature: sig, to: body)
        XCTAssertEqual(result, body)
    }

    func testCustomDedupIgnoresTrailingWhitespaceDifferences() {
        let body = "Sounds good.\n\nBest,\nJane Doe\nAcme Corp   \n\n"
        let result = SignatureApplier.apply(policy: .custom, signature: sig, to: body)
        XCTAssertEqual(result, body)
    }

    // MARK: - Policy: custom — empty inputs

    func testCustomWithEmptySignatureLeavesBodyUnchanged() {
        let body = "Sounds good."
        XCTAssertEqual(SignatureApplier.apply(policy: .custom, signature: "   ", to: body), body)
    }

    func testCustomWithEmptyBodyLeavesItUnchanged() {
        // A flagged outcome (needs-info / not-reply-worthy) carries an empty body;
        // no signature should be bolted onto a non-reply.
        XCTAssertEqual(SignatureApplier.apply(policy: .custom, signature: sig, to: ""), "")
    }

    // MARK: - Quoted history placement

    func testSignaturePlacedAboveQuotedHistory() {
        let body = "Sounds good, see you then.\n\nOn Mon, Bob wrote:\n> can you make it?"
        let result = SignatureApplier.apply(policy: .custom, signature: sig, to: body)
        XCTAssertEqual(
            result,
            "Sounds good, see you then.\n\n\(sig)\n\nOn Mon, Bob wrote:\n> can you make it?"
        )
    }

    func testEmbeddedBlockquoteStaysWithFreshReply() {
        let body = "Intro\n> excerpt\nConclusion"
        let result = SignatureApplier.apply(policy: .custom, signature: sig, to: body)
        XCTAssertEqual(result, "Intro\n> excerpt\nConclusion\n\n\(sig)")
    }

    func testQuotedHistoryLeftIntactWhenAlreadySigned() {
        let body = "Sounds good.\n\n\(sig)\n\nOn Mon, Bob wrote:\n> can you make it?"
        let result = SignatureApplier.apply(policy: .custom, signature: sig, to: body)
        XCTAssertEqual(result, body)
    }

    // MARK: - Idempotency

    func testApplyIsIdempotent() {
        let body = "Sounds good, see you then."
        let once = SignatureApplier.apply(policy: .custom, signature: sig, to: body)
        let twice = SignatureApplier.apply(policy: .custom, signature: sig, to: once)
        XCTAssertEqual(once, twice)
    }
}
