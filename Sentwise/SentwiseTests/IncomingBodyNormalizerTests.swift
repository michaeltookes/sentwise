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

    func testPreservesIntrawordDoubleUnderscores() {
        XCTAssertEqual(IncomingBodyNormalizer.normalize("The token is FOO__BAR."), "The token is FOO__BAR.")
    }

    func testPreservesUnpairedDoubleUnderscores() {
        XCTAssertEqual(IncomingBodyNormalizer.normalize("Keep this __ marker."), "Keep this __ marker.")
    }

    func testPreservesEmphasisDelimitersInsideCodeSpans() {
        XCTAssertEqual(
            IncomingBodyNormalizer.normalize("Call `__init__` before use"),
            "Call __init__ before use"
        )
    }

    func testPreservesEmphasisDelimitersInsideMultiBacktickCodeSpans() {
        XCTAssertEqual(
            IncomingBodyNormalizer.normalize("Call ``__init__`` before use"),
            "Call __init__ before use"
        )
        XCTAssertEqual(
            IncomingBodyNormalizer.normalize("Use ``a`b`` in examples"),
            "Use a`b in examples"
        )
    }

    func testPreservesMarkdownLinksInsideCodeSpans() {
        XCTAssertEqual(
            IncomingBodyNormalizer.normalize("Use `[docs](url)` as the fixture"),
            "Use [docs](url) as the fixture"
        )
    }

    func testPreservesWhitespaceInsideCodeSpans() {
        XCTAssertEqual(
            IncomingBodyNormalizer.normalize("Use `a  b` as the fixture"),
            "Use a  b as the fixture"
        )
    }

    func testPreservesFencedCodeBlockContents() {
        let input = """
        Before

        ```
        **literal**
        [docs](url)
        a  b
        ```

        After
        """
        let expected = """
        Before

        **literal**
        [docs](url)
        a  b

        After
        """

        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), expected)
    }

    func testFenceDelimiterWithContentDoesNotCloseCodeBlock() {
        let input = """
        ```
        ```not-a-close
        **literal**
        ```
        """
        let expected = """
        ```not-a-close
        **literal**
        """

        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), expected)
    }

    func testPreservesRepeatedUnmatchedEmphasisOpeners() {
        let input = "Start" + String(repeating: " **a", count: 200)

        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), input)
    }

    func testSimplifiesMarkdownLinks() {
        let input = "See [the docs](https://example.com/tracking?id=abc123) for more."
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), "See the docs for more.")
    }

    func testSimplifiesMarkdownLinksWithBalancedDestinationParentheses() {
        let input = "See [docs](https://example.com/a_(b)) for details."
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), "See docs for details.")
    }

    func testSimplifiesMarkdownLinksWithEscapedDestinationParentheses() {
        let input = "See [docs](https://example.com/a\\)b) for details."
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), "See docs for details.")
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
        // NBSP becomes a real space; the artifact characters are removed
        // outright, so the tokens they sat between join up.
        let input = "\u{FEFF}Hello\u{00A0}there\u{200B}friend"
        XCTAssertEqual(IncomingBodyNormalizer.normalize(input), "Hello therefriend")
    }

    func testPreservesSemanticZeroWidthJoiners() {
        let emojiSequence = "Family: 👨\u{200D}👩\u{200D}👧\u{200D}👦"
        let persianWithZWNJ = "Persian: می\u{200C}روم"

        XCTAssertEqual(IncomingBodyNormalizer.normalize(emojiSequence), emojiSequence)
        XCTAssertEqual(IncomingBodyNormalizer.normalize(persianWithZWNJ), persianWithZWNJ)
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
