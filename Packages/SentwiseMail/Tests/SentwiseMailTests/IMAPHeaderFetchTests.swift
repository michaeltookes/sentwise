import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import SentwiseMail

/// Drives `IMAPHeaderFetchHandler` through the real IMAP decoder with an
/// `EmbeddedChannel`, feeding raw server responses — deterministic coverage of
/// the LOGIN → SELECT → UID FETCH (BODY.PEEK[HEADER.FIELDS (...)]) state machine
/// and the header parsing, no server.
final class IMAPHeaderFetchTests: XCTestCase {

    private func makeChannel(
        uid: UInt32 = 101,
        mailbox: String = "INBOX",
        expectedUIDValidity: UInt32? = nil
    ) throws -> (EmbeddedChannel, EventLoopFuture<MailHeaderFields>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: MailHeaderFields.self)
        let handler = IMAPHeaderFetchHandler(
            email: "me@gmail.com",
            password: "pw",
            mailboxName: mailbox,
            uid: uid,
            expectedUIDValidity: expectedUIDValidity,
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([IMAPClientHandler(), handler])
        return (channel, promise.futureResult)
    }

    @discardableResult
    private func feed(_ channel: EmbeddedChannel, _ response: String) throws -> String {
        try channel.writeInbound(ByteBuffer(string: response))
        var out = ""
        while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
            out += String(buffer: buffer)
        }
        return out
    }

    private func headerSection(_ block: String, bodyStructure: String? = nil) -> String {
        let structureAttribute = bodyStructure.map { "BODYSTRUCTURE \($0) " } ?? ""
        return "* 1 FETCH (UID 101 \(structureAttribute)BODY[HEADER.FIELDS "
            + "(LIST-ID LIST-UNSUBSCRIBE PRECEDENCE AUTO-SUBMITTED "
            + "X-AUTO-RESPONSE-SUPPRESS CONTENT-TYPE)] {\(block.utf8.count)}\r\n\(block))\r\n"
    }

    func testFetchRequestIncludesBodyStructureAndHeaderFields() throws {
        let (channel, _) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        let command = try feed(channel, "A2 OK SELECT completed\r\n")

        XCTAssertTrue(command.contains("BODYSTRUCTURE"))
        XCTAssertTrue(command.contains("BODY.PEEK[HEADER.FIELDS"))
        _ = try? channel.finish()
    }

    func testParsesListAndPrecedenceHeaders() throws {
        let (channel, future) = try makeChannel()
        let block = "List-Id: Widgets <widgets.example.com>\r\n"
            + "List-Unsubscribe: <mailto:unsub@example.com>\r\n"
            + "Precedence: bulk\r\n\r\n"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* 3 EXISTS\r\n")
        try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")
        try feed(channel, headerSection(block))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let fields = try future.wait()
        XCTAssertEqual(fields.listID, "Widgets <widgets.example.com>")
        XCTAssertEqual(fields.listUnsubscribe, "<mailto:unsub@example.com>")
        XCTAssertEqual(fields.precedence, "bulk")
        XCTAssertNil(fields.contentType)
        _ = try? channel.finish()
    }

    func testParsesCalendarContentTypeAndAutomationHeaders() throws {
        let (channel, future) = try makeChannel()
        let block = "Auto-Submitted: auto-generated\r\n"
            + "X-Auto-Response-Suppress: All\r\n"
            + "Content-Type: text/calendar; method=REQUEST; charset=UTF-8\r\n\r\n"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, headerSection(block))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let fields = try future.wait()
        XCTAssertEqual(fields.autoSubmitted, "auto-generated")
        XCTAssertEqual(fields.autoResponseSuppress, "All")
        XCTAssertEqual(fields.contentType, "text/calendar; method=REQUEST; charset=UTF-8")
        _ = try? channel.finish()
    }

    func testParsesNestedCalendarContentTypeFromBodyStructure() throws {
        let (channel, future) = try makeChannel()
        let block = "Content-Type: multipart/alternative; boundary=abc\r\n\r\n"
        let bodyStructure =
            #"("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 12 1 NIL NIL NIL NIL)"#
            + #"("TEXT" "CALENDAR" ("METHOD" "REQUEST") NIL NIL "7BIT" 88 5 NIL NIL NIL NIL)"#
            + #" "ALTERNATIVE" ("BOUNDARY" "abc") NIL NIL NIL"#

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, headerSection(block, bodyStructure: "(\(bodyStructure))"))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let fields = try future.wait()
        XCTAssertEqual(fields.contentType, "multipart/alternative; boundary=abc")
        XCTAssertEqual(
            fields.bodyContentTypes,
            ["multipart/alternative", "text/plain", "text/calendar; method=REQUEST"]
        )
        _ = try? channel.finish()
    }

    func testOmitsCalendarAttachmentContentTypeFromBodyStructure() throws {
        let (channel, future) = try makeChannel()
        let block = "Content-Type: multipart/mixed; boundary=abc\r\n\r\n"
        let textPart = #"("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 12 1 NIL NIL NIL NIL)"#
        let attachmentPart =
            #"("APPLICATION" "ICS" ("NAME" "invite.ics") NIL NIL "BASE64" 88 NIL "# +
            #"("ATTACHMENT" ("FILENAME" "invite.ics")) NIL NIL)"#
        let bodyStructure = "\(textPart)\(attachmentPart) \"MIXED\" (\"BOUNDARY\" \"abc\") NIL NIL NIL"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, headerSection(block, bodyStructure: "(\(bodyStructure))"))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let fields = try future.wait()
        XCTAssertEqual(fields.contentType, "multipart/mixed; boundary=abc")
        XCTAssertEqual(fields.bodyContentTypes, ["multipart/mixed", "text/plain"])
        _ = try? channel.finish()
    }

    func testPreservesCalendarRequestAttachmentContentTypeFromBodyStructure() throws {
        let (channel, future) = try makeChannel()
        let block = "Content-Type: multipart/mixed; boundary=abc\r\n\r\n"
        let textPart = #"("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 12 1 NIL NIL NIL NIL)"#
        let attachmentPart =
            #"("TEXT" "CALENDAR" ("METHOD" "REQUEST" "NAME" "invite.ics") NIL NIL "BASE64" 88 5 NIL "# +
            #"("ATTACHMENT" ("FILENAME" "invite.ics")) NIL NIL)"#
        let bodyStructure = "\(textPart)\(attachmentPart) \"MIXED\" (\"BOUNDARY\" \"abc\") NIL NIL NIL"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, headerSection(block, bodyStructure: "(\(bodyStructure))"))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let fields = try future.wait()
        XCTAssertEqual(fields.contentType, "multipart/mixed; boundary=abc")
        XCTAssertEqual(
            fields.bodyContentTypes,
            ["multipart/mixed", "text/plain", "text/calendar; method=REQUEST"]
        )
        _ = try? channel.finish()
    }

    func testOmitsCalendarRequestInsideAttachedMessageBodyStructure() throws {
        let (channel, future) = try makeChannel()
        let block = "Content-Type: multipart/mixed; boundary=abc\r\n\r\n"
        let textPart = #"("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 12 1 NIL NIL NIL NIL)"#
        let attachedMessage =
            #""MESSAGE" "RFC822" ("NAME" "forwarded.eml") NIL NIL "BASE64" 400 "# +
            #"(NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL) "# +
            #"(("TEXT" "CALENDAR" ("METHOD" "REQUEST") NIL NIL "7BIT" 88 5) "MIXED") "# +
            #"12 NIL ("ATTACHMENT" ("FILENAME" "forwarded.eml")) NIL NIL"#
        let bodyStructure = "\(textPart)(\(attachedMessage)) \"MIXED\" (\"BOUNDARY\" \"abc\") NIL NIL NIL"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, headerSection(block, bodyStructure: "(\(bodyStructure))"))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let fields = try future.wait()
        XCTAssertEqual(fields.contentType, "multipart/mixed; boundary=abc")
        XCTAssertEqual(fields.bodyContentTypes, ["multipart/mixed", "text/plain"])
        _ = try? channel.finish()
    }

    func testUnfoldsFoldedHeaderValues() throws {
        let (channel, future) = try makeChannel()
        // A List-Unsubscribe folded across two lines must reassemble intact.
        let block = "List-Unsubscribe: <mailto:unsub@example.com>,\r\n"
            + " <https://example.com/unsub>\r\n\r\n"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, headerSection(block))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let fields = try future.wait()
        XCTAssertEqual(
            fields.listUnsubscribe,
            "<mailto:unsub@example.com>, <https://example.com/unsub>"
        )
        _ = try? channel.finish()
    }

    func testFetchWithoutHeaderSectionReturnsEmptyFields() throws {
        // A plain personal message carries none of the requested headers; the
        // server returns an empty section, which is a valid reply-worthy result.
        let (channel, future) = try makeChannel()
        let block = "\r\n"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, headerSection(block))
        try feed(channel, "A3 OK FETCH completed\r\n")

        XCTAssertEqual(try future.wait(), MailHeaderFields())
        _ = try? channel.finish()
    }

    func testFetchOKWithNoBodySectionReturnsEmptyFields() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, "A3 OK FETCH completed\r\n")

        XCTAssertEqual(try future.wait(), MailHeaderFields())
        _ = try? channel.finish()
    }

    func testUIDValidityMismatchSurfacesCommandError() throws {
        let (channel, future) = try makeChannel(expectedUIDValidity: 123)

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* OK [UIDVALIDITY 456] UIDs valid\r\n")
        try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            XCTAssertEqual(
                error as? MailError,
                .commandFailed("The mailbox changed before the message headers were fetched.")
            )
        }
        _ = try? channel.finish()
    }

    func testLoginFailureSurfacesAuthenticationError() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .authenticationFailed = error as? MailError else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
        _ = try? channel.finish()
    }

    func testSelectFailureSurfacesCommandError() throws {
        let (channel, future) = try makeChannel(mailbox: "[Gmail]/Does Not Exist")

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 NO Unknown mailbox\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .commandFailed = error as? MailError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
        }
        _ = try? channel.finish()
    }
}
