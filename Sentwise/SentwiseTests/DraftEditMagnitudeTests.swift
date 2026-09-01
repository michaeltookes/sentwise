import XCTest
@testable import Sentwise

/// Tests for the pure edit-magnitude metric (item 83, Phase 1): the normalized
/// character-level Levenshtein ratio over an original vs. final draft body.
final class DraftEditMagnitudeTests: XCTestCase {

    func testIdenticalBodiesAreZero() {
        XCTAssertEqual(DraftEditMagnitude.ratio(original: "Thanks, that works.", final: "Thanks, that works."), 0)
    }

    func testBothEmptyIsZero() {
        XCTAssertEqual(DraftEditMagnitude.ratio(original: "", final: ""), 0)
    }

    func testWhitespaceOnlyDifferenceNormalizesToZero() {
        // Reflow / extra spacing / trailing newlines must not register as an edit.
        let original = "Hi Alice,\n\nThursday works for me.\n"
        let final = "  Hi Alice,   Thursday works for me.  "
        XCTAssertEqual(DraftEditMagnitude.ratio(original: original, final: final), 0)
    }

    func testCompleteRewriteIsOne() {
        // No shared characters after normalization → distance == max length → 1.
        XCTAssertEqual(DraftEditMagnitude.ratio(original: "aaaa", final: "bbbb"), 1)
    }

    func testEmptyOriginalToNonEmptyIsOne() {
        XCTAssertEqual(DraftEditMagnitude.ratio(original: "", final: "Hello there"), 1)
    }

    func testSmallEditIsSmallMagnitude() {
        // One character changed in a 20-char (normalized) string → ~0.05.
        let original = "Thursday works for me"
        let final = "Thursday works for us"
        let ratio = DraftEditMagnitude.ratio(original: original, final: final)
        XCTAssertGreaterThan(ratio, 0)
        XCTAssertLessThan(ratio, 0.1)
    }

    func testMagnitudeIsBoundedAndMonotonicWithEditSize() {
        let base = "The quick brown fox jumps over the lazy dog"
        let oneWord = "The quick brown cat jumps over the lazy dog"
        let manyWords = "A slow green turtle crawls beneath the lazy dog"
        let small = DraftEditMagnitude.ratio(original: base, final: oneWord)
        let large = DraftEditMagnitude.ratio(original: base, final: manyWords)
        XCTAssertGreaterThan(large, small)
        XCTAssertGreaterThanOrEqual(small, 0)
        XCTAssertLessThanOrEqual(large, 1)
    }

    func testMetricIsSymmetric() {
        let a = "Let's meet Tuesday at noon"
        let b = "Let's meet Wednesday at noon"
        XCTAssertEqual(
            DraftEditMagnitude.ratio(original: a, final: b),
            DraftEditMagnitude.ratio(original: b, final: a),
            accuracy: 1e-12
        )
    }
}
