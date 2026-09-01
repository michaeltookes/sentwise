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
        let first = "Let's meet Tuesday at noon"
        let second = "Let's meet Wednesday at noon"
        XCTAssertEqual(
            DraftEditMagnitude.ratio(original: first, final: second),
            DraftEditMagnitude.ratio(original: second, final: first),
            accuracy: 1e-12
        )
    }

    func testLargeEditedBodiesUseBoundedApproximation() {
        let length = Int(Double(DraftEditMagnitude.exactDistanceCellLimit).squareRoot()) + 1
        let middle = length / 2
        var edited = Array(String(repeating: "a", count: length))
        edited[middle] = "b"

        XCTAssertGreaterThan(length * length, DraftEditMagnitude.exactDistanceCellLimit)
        XCTAssertEqual(
            DraftEditMagnitude.ratio(original: String(repeating: "a", count: length), final: String(edited)),
            1 / Double(length),
            accuracy: 1e-12
        )
    }

    func testLargeSparseEditsStaySmall() {
        let length = Int(Double(DraftEditMagnitude.exactDistanceCellLimit).squareRoot()) + 2
        var edited = Array(String(repeating: "a", count: length))
        edited[3] = "b"
        edited[length - 4] = "c"

        XCTAssertGreaterThan(length * length, DraftEditMagnitude.exactDistanceCellLimit)
        XCTAssertEqual(
            DraftEditMagnitude.ratio(original: String(repeating: "a", count: length), final: String(edited)),
            2 / Double(length),
            accuracy: 1e-12
        )
    }

    func testLargeSeparatedInsertionsStaySmall() {
        let length = Int(Double(DraftEditMagnitude.exactDistanceCellLimit).squareRoot()) + 2
        let original = String(repeating: "a", count: length)
        var edited = Array(original)
        edited.insert("b", at: 4)
        edited.insert("c", at: edited.count - 4)

        XCTAssertGreaterThan(original.count * edited.count, DraftEditMagnitude.exactDistanceCellLimit)
        XCTAssertEqual(
            DraftEditMagnitude.ratio(original: original, final: String(edited)),
            2 / Double(edited.count),
            accuracy: 1e-12
        )
    }

    func testLargeMovedBlockBeyondResyncWindowStaysSmall() {
        let length = Int(Double(DraftEditMagnitude.exactDistanceCellLimit).squareRoot()) + 1
        let movedSuffixLength = 65
        let scalars = (0..<length).map { UnicodeScalar(0xE000 + $0)! }
        let original = String(String.UnicodeScalarView(scalars))
        let final = String(original.suffix(movedSuffixLength))
            + String(original.prefix(length - movedSuffixLength))

        XCTAssertGreaterThan(original.count * final.count, DraftEditMagnitude.exactDistanceCellLimit)
        XCTAssertEqual(
            DraftEditMagnitude.ratio(original: original, final: final),
            Double(movedSuffixLength * 2) / Double(length),
            accuracy: 1e-12
        )
    }

    func testLargeRewriteMagnitudeIsBounded() {
        let length = Int(Double(DraftEditMagnitude.exactDistanceCellLimit).squareRoot()) + 1

        XCTAssertEqual(
            DraftEditMagnitude.ratio(
                original: String(repeating: "a", count: length),
                final: String(repeating: "b", count: length)
            ),
            1
        )
    }
}
