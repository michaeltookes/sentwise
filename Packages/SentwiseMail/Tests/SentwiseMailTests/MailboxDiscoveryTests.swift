import XCTest
@testable import SentwiseMail

/// Microsoft folder naming and SPECIAL-USE discovery over scripted LIST
/// responses (item 31, T31-8). No network.
final class MailboxDiscoveryTests: XCTestCase {

    func testMicrosoftDefaults() {
        let naming = MailboxNaming.microsoft
        XCTAssertEqual(naming.sent, "Sent Items")
        XCTAssertEqual(naming.drafts, "Drafts")
        XCTAssertEqual(naming.junk, "Junk Email")
        XCTAssertEqual(naming.trash, "Deleted Items")
        XCTAssertEqual(naming.archive, "Archive")
        XCTAssertNil(naming.allMail)
    }

    func testMicrosoftHostsResolveToMicrosoftAndOthersAreUnchanged() {
        XCTAssertEqual(MailboxNaming.forHost("outlook.office365.com"), .microsoft)
        XCTAssertEqual(MailboxNaming.forHost("OUTLOOK.OFFICE365.COM"), .microsoft)
        XCTAssertEqual(MailboxNaming.forHost("imap.gmail.com"), .gmail)
        XCTAssertEqual(MailboxNaming.forHost("imap.mail.yahoo.com"), .yahoo)
        XCTAssertEqual(MailboxNaming.forHost("imap.fastmail.com"), .generic)
    }

    func testAttributesPresentOverrideDefaults() {
        let lines = [
            #"* LIST (\HasNoChildren) "/" "INBOX""#,
            #"* LIST (\HasNoChildren \Sent) "/" "Sent""#,
            #"* LIST (\HasNoChildren \Drafts) "/" "Entwürfe""#,
            #"* LIST (\HasNoChildren \Junk) "/" "Spam Mail""#,
            #"* LIST (\HasNoChildren \Trash) "/" "Papierkorb""#,
            #"* LIST (\HasNoChildren \Archive) "/" "Archiv""#
        ]
        let naming = MailboxNaming.microsoft.discovering(from: MailboxNaming.parseListResponses(lines))
        XCTAssertEqual(naming.sent, "Sent")
        XCTAssertEqual(naming.drafts, "Entwürfe")
        XCTAssertEqual(naming.junk, "Spam Mail")
        XCTAssertEqual(naming.trash, "Papierkorb")
        XCTAssertEqual(naming.archive, "Archiv")
    }

    func testAttributesAbsentKeepDocumentedOutlookDefaults() {
        let lines = [
            #"* LIST (\HasNoChildren) "/" "INBOX""#,
            #"* LIST (\HasNoChildren) "/" "Sent Items""#
        ]
        let naming = MailboxNaming.microsoft.discovering(from: MailboxNaming.parseListResponses(lines))
        XCTAssertEqual(naming, .microsoft)
    }

    func testPartialAttributesOnlyOverrideWhatIsMarked() {
        let lines = [#"* LIST (\Sent) "/" "Elementos enviados""#]
        let naming = MailboxNaming.microsoft.discovering(from: MailboxNaming.parseListResponses(lines))
        XCTAssertEqual(naming.sent, "Elementos enviados")
        XCTAssertEqual(naming.drafts, "Drafts")
        XCTAssertEqual(naming.trash, "Deleted Items")
    }

    func testLocalizedModifiedUTF7NamesAreDecoded() {
        let lines = [
            #"* LIST (\Sent) "/" "Gesendete Elemente""#,
            #"* LIST (\Trash) "/" "&AMQ-ndert""#,
            #"* LIST (\Drafts) "/" "Entw&APw-rfe""#
        ]
        let naming = MailboxNaming.microsoft.discovering(from: MailboxNaming.parseListResponses(lines))
        XCTAssertEqual(naming.sent, "Gesendete Elemente")
        XCTAssertEqual(naming.trash, "Ändert")
        XCTAssertEqual(naming.drafts, "Entwürfe")
    }

    func testXLISTDialectAndSpamAliasAreUnderstood() {
        let lines = [
            #"* XLIST (\Inbox) "/" "INBOX""#,
            #"* XLIST (\Spam) "/" "Courrier indésirable""#,
            #"* XLIST (\Sent) "/" "Éléments envoyés""#
        ]
        let naming = MailboxNaming.microsoft.discovering(from: MailboxNaming.parseListResponses(lines))
        XCTAssertEqual(naming.junk, "Courrier indésirable")
        XCTAssertEqual(naming.sent, "Éléments envoyés")
    }

    func testNilDelimiterUnquotedNamesAndNonListLinesAreHandled() {
        let lines = [
            "* OK still here",
            "A1 OK LIST completed",
            #"* LIST (\Drafts) NIL Drafts"#,
            #"* LIST (\Archive) "." Archive"#
        ]
        let entries = MailboxNaming.parseListResponses(lines)
        XCTAssertEqual(entries.map(\.name), ["Drafts", "Archive"])
    }

    func testGmailNamingIsNeverTouchedByDiscoveryDefaults() {
        XCTAssertEqual(MailboxNaming.forHost("imap.gmail.com"), .gmail)
        XCTAssertEqual(MailboxNaming.gmail.sent, "[Gmail]/Sent Mail")
        XCTAssertEqual(MailboxNaming.gmail.discovering(from: []), .gmail)
    }

    func testModifiedUTF7AmpersandEscape() {
        XCTAssertEqual(ModifiedUTF7.decode("R&-D"), "R&D")
        XCTAssertEqual(ModifiedUTF7.decode("Plain"), "Plain")
    }

    func testLiteralMailboxNameIsConsumedByDeclaredLength() {
        let lines = [
            "* LIST (\\HasNoChildren \\Sent) \"/\" {10}", "Sent Items",
            "* LIST (\\Drafts) \"/\" \"Drafts\""
        ]
        let entries = MailboxNaming.parseListResponses(lines)
        XCTAssertEqual(entries.map(\.name), ["Sent Items", "Drafts"])
        let naming = MailboxNaming.microsoft.discovering(from: entries)
        XCTAssertEqual(naming.sent, "Sent Items")
        XCTAssertNotEqual(naming.sent, "{10}")
    }

    func testLiteralSpanningLineBoundaryAndTruncatedLiteral() {
        // The literal's own CRLF splits it across two elements: 4 bytes "A\r\nB".
        let spanning = MailboxNaming.parseListResponses(["* LIST (\\Trash) \"/\" {4}", "A", "B"])
        XCTAssertEqual(spanning.map(\.name), ["A\r\nB"])
        // A literal whose data never arrived yields no entry, not a "{n}" name.
        XCTAssertTrue(MailboxNaming.parseListResponses(["* LIST (\\Sent) \"/\" {10}"]).isEmpty)
    }
}
