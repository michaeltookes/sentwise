import XCTest
@testable import Sentwise

final class MIMEEncodedWordTests: XCTestCase {

    func testPlainAsciiIsUnchanged() {
        XCTAssertEqual(MIMEEncodedWord.decode("Re: Lunch on Friday?"), "Re: Lunch on Friday?")
    }

    func testEmptyStringIsUnchanged() {
        XCTAssertEqual(MIMEEncodedWord.decode(""), "")
    }

    func testDisplaySubjectDecodesAndFallsBackForEmpty() {
        let encoded = Data("Café".utf8).base64EncodedString()

        XCTAssertEqual(MIMEEncodedWord.displaySubject("=?UTF-8?B?\(encoded)?="), "Café")
        XCTAssertEqual(MIMEEncodedWord.displaySubject(""), "(no subject)")
    }

    func testBase64UTF8EncodedWord() {
        // "Café ☕" base64-encoded as UTF-8.
        let encoded = Data("Café ☕".utf8).base64EncodedString()
        XCTAssertEqual(MIMEEncodedWord.decode("=?UTF-8?B?\(encoded)?="), "Café ☕")
    }

    func testQuotedPrintableEncodedWord() {
        // =C3=A9 is é in UTF-8; underscore decodes to a space.
        XCTAssertEqual(MIMEEncodedWord.decode("=?UTF-8?Q?Caf=C3=A9_time?="), "Café time")
    }

    func testQuotedPrintableUnderscoreIsSpace() {
        XCTAssertEqual(MIMEEncodedWord.decode("=?UTF-8?Q?a_b_c?="), "a b c")
    }

    func testMixedPlainAndEncodedText() {
        let encoded = Data("Café".utf8).base64EncodedString()
        XCTAssertEqual(
            MIMEEncodedWord.decode("Re: your visit to =?UTF-8?B?\(encoded)?= today"),
            "Re: your visit to Café today"
        )
    }

    func testAdjacentEncodedWordsCollapseSeparatingWhitespace() {
        // Two encoded-words split a long word; the whitespace between them is
        // per RFC 2047 not part of the text and must be dropped.
        let first = Data("Hello".utf8).base64EncodedString()
        let second = Data("World".utf8).base64EncodedString()
        XCTAssertEqual(
            MIMEEncodedWord.decode("=?UTF-8?B?\(first)?= =?UTF-8?B?\(second)?="),
            "HelloWorld"
        )
    }

    func testWhitespaceAroundNonAdjacentEncodedWordsIsPreserved() {
        // Plain text between the words keeps its surrounding spaces.
        let first = Data("Hello".utf8).base64EncodedString()
        let second = Data("World".utf8).base64EncodedString()
        XCTAssertEqual(
            MIMEEncodedWord.decode("=?UTF-8?B?\(first)?= dear =?UTF-8?B?\(second)?="),
            "Hello dear World"
        )
    }

    func testLatin1QuotedPrintable() {
        // 0xE9 is é in ISO-8859-1.
        XCTAssertEqual(MIMEEncodedWord.decode("=?ISO-8859-1?Q?Caf=E9?="), "Café")
    }

    func testLatin1Alias() {
        XCTAssertEqual(MIMEEncodedWord.decode("=?latin1?Q?Caf=E9?="), "Café")
    }

    func testUSAsciiEncodedWord() {
        let encoded = Data("Hello".utf8).base64EncodedString()
        XCTAssertEqual(MIMEEncodedWord.decode("=?US-ASCII?B?\(encoded)?="), "Hello")
    }

    func testCaseInsensitiveEncodingToken() {
        let encoded = Data("Hi".utf8).base64EncodedString()
        XCTAssertEqual(MIMEEncodedWord.decode("=?UTF-8?b?\(encoded)?="), "Hi")
    }

    func testUnknownCharsetFallsBackToRaw() {
        let raw = "=?NOT-A-CHARSET?B?SGVsbG8=?="
        XCTAssertEqual(MIMEEncodedWord.decode(raw), raw)
    }

    func testInvalidBase64FallsBackToRaw() {
        let raw = "=?UTF-8?B?not_valid_base64!!?="
        XCTAssertEqual(MIMEEncodedWord.decode(raw), raw)
    }

    func testEmptyEncodedWordPayloadFallsBackToRaw() {
        let raw = "=?UTF-8?B??="
        XCTAssertEqual(MIMEEncodedWord.decode(raw), raw)
        XCTAssertEqual(MIMEEncodedWord.displaySubject(raw), raw)
    }

    func testTruncatedQuotedPrintableEscapeFallsBackToRaw() {
        let raw = "=?UTF-8?Q?Caf=E?="   // dangling =E, missing a hex digit
        XCTAssertEqual(MIMEEncodedWord.decode(raw), raw)
    }

    func testUnknownEncodingTokenFallsBackToRaw() {
        // Regex only matches B/Q, so an X-encoding word is never touched.
        let raw = "=?UTF-8?X?whatever?="
        XCTAssertEqual(MIMEEncodedWord.decode(raw), raw)
    }

    func testMalformedWordAmidValidTextKeepsOtherDecodes() {
        let good = Data("Hi".utf8).base64EncodedString()
        let input = "=?UTF-8?B?\(good)?= and =?BADSET?B?SGVsbG8=?="
        XCTAssertEqual(MIMEEncodedWord.decode(input), "Hi and =?BADSET?B?SGVsbG8=?=")
    }

    func testNoCrashOnLoneEqualsQuestion() {
        XCTAssertEqual(MIMEEncodedWord.decode("just =? a fragment"), "just =? a fragment")
    }
}
