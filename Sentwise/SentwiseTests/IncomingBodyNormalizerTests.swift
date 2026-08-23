import XCTest
@testable import Sentwise

final class IncomingBodyNormalizerTests: XCTestCase {

    func testEmptyStringIsUnchanged() {
        XCTAssertEqual(IncomingBodyNormalizer.normalize(""), "")
    }

    func testPlainProseIsPreserved() {
        let input = "Hi Priya,\n\nThanks for the note. Talk soon.\n\nMarcus"
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), input)
    }

    func testStripsHeadingMarkers() {
        XCTAssertEqual(IncomingBodyNormalizer.normalize("### Release notes"), "Release notes")
        XCTAssertEqual(IncomingBodyNormalizer.normalize("# Title"), "Title")
    }

    func testKeepsHashWithoutSpaceUntouched() {
        // "#1" is not a heading — no space after the hashes.
        XCTAssertEqual(IncomingBodyNormalizer.normalize("#1 priority"), "#1 priority")
    }

    func testStripsBoldMarkers() {
        XCTAssertEqual(IncomingBodyNormalizer.normalize("This is **important** news"), "This is important news")
    }

    func testStripsUnderscoreBoldAndBackticks() {
        XCTAssertEqual(IncomingBodyNormalizer.normalize("__loud__ and `code`"), "loud and code")
    }

    func testSimplifiesMarkdownLinks() {
        let input = "See [the docs](https://example.com/tracking?id=abc123) for more."
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), "See the docs for more.")
    }

    func testCollapsesExcessiveBlankLines() {
        let input = "First paragraph.\n\n\n\n\nSecond paragraph."
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), "First paragraph.\n\nSecond paragraph.")
    }

    func testRemovesHorizontalRules() {
        let input = "Above the line\n\n-----\n\nBelow the line"
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), "Above the line\n\nBelow the line")
    }

    func testRemovesEqualsAndAsteriskRules() {
        // The rule line is dropped and reads as a paragraph break between the
        // lines it separated.
        XCTAssertEqual(
            IncomingBodyNormalizer.normalize("Header\n=====\nBody"),
            "Header\n\nBody"
        )
        XCTAssertEqual(
            IncomingBodyNormalizer.normalize("Header\n***\nBody"),
            "Header\n\nBody"
        )
    }

    func testNormalizesCRLFLineEndings() {
        XCTAssertEqual(IncomingBodyNormalizer.normalize("a\r\nb\r\nc"), "a\nb\nc")
    }

    func testConvertsListMarkersToBullets() {
        let input = "* first\n* second\n- third"
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), "• first\n• second\n• third")
    }

    func testStripsBlockquoteMarkers() {
        XCTAssertEqual(IncomingBodyNormalizer.normalize("> quoted reply"), "quoted reply")
    }

    func testCollapsesInteriorSpaceRuns() {
        XCTAssertEqual(IncomingBodyNormalizer.normalize("too      many     spaces"), "too many spaces")
    }

    func testNeutralisesNonBreakingAndZeroWidthSpaces() {
        // NBSP becomes a real space; the zero-width space is removed outright, so
        // the tokens it sat between join up.
        let input = "Hello\u{00A0}there\u{200B}friend"
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), "Hello therefriend")
    }

    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(IncomingBodyNormalizer.normalize("\n\n  Hello  \n\n"), "Hello")
    }

    func testCombinedGitHubStyleNotification() {
        let input = """
        ## New pull request

        **alice** opened [#42](https://github.com/x/y/pull/42)

        ---

        Please review when you get a chance.
        """
        let expected = """
        New pull request

        alice opened #42

        Please review when you get a chance.
        """
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), expected)
    }
}
