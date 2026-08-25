import Foundation
import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import SentwiseMail

/// Drives `IMAPSearchHandler` through the real IMAP decoder with an
/// `EmbeddedChannel`, feeding raw server responses — deterministic coverage of
/// the LOGIN → SELECT → UID SEARCH → UID FETCH state machine, paging, and
/// criteria encoding, with no server.
final class IMAPSearchTests: XCTestCase {

    private func makeChannel(
        criteria: MailSearchCriteria = MailSearchCriteria(),
        offset: Int = 0,
        limit: Int = 50,
        mailbox: String = "INBOX",
        calendar: Calendar = .current
    ) throws -> (EmbeddedChannel, EventLoopFuture<MailSearchResult>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: MailSearchResult.self)
        let handler = IMAPSearchHandler(
            email: "me@gmail.com",
            password: "pw",
            mailboxName: mailbox,
            criteria: criteria,
            offset: offset,
            limit: limit,
            calendar: calendar,
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([IMAPClientHandler(), handler])
        return (channel, promise.futureResult)
    }

    /// Feeds a raw server response and returns everything the client wrote in
    /// reaction (so a test can assert the command bytes that went out).
    @discardableResult
    private func feed(_ channel: EmbeddedChannel, _ response: String) throws -> String {
        try channel.writeInbound(ByteBuffer(string: response))
        var out = ""
        while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
            out += String(buffer: buffer)
        }
        return out
    }

    private func envelope(uid: UInt32, seq: UInt32, subject: String, from: String) -> String {
        "* \(seq) FETCH (UID \(uid) ENVELOPE (\"Wed, 1 Jan 2026 10:00:00 +0000\" "
            + "\"\(subject)\" ((\"Sender\" NIL \"\(from)\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n"
    }

    /// Drives greeting → login → select for a test, returning the outbound the
    /// SELECT's OK triggered (i.e. the UID SEARCH command bytes).
    @discardableResult
    private func advanceThroughSelect(_ channel: EmbeddedChannel) throws -> String {
        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* OK [UIDVALIDITY 123456] UIDs valid\r\n")
        return try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")
    }

    // MARK: - Paging (pure)

    func testPagingReturnsNewestFirst() {
        let (page, total, hasMore) = MailSearchPaging.page(matchedUIDs: [101, 103, 102], offset: 0, limit: 10)
        XCTAssertEqual(page, [103, 102, 101])
        XCTAssertEqual(total, 3)
        XCTAssertFalse(hasMore)
    }

    func testPagingFirstPageHasMore() {
        let (page, total, hasMore) = MailSearchPaging.page(matchedUIDs: [101, 102, 103, 104, 105], offset: 0, limit: 2)
        XCTAssertEqual(page, [105, 104])
        XCTAssertEqual(total, 5)
        XCTAssertTrue(hasMore)
    }

    func testPagingSecondPageHasNoMore() {
        let (page, total, hasMore) = MailSearchPaging.page(matchedUIDs: [101, 102, 103, 104], offset: 2, limit: 2)
        XCTAssertEqual(page, [102, 101])
        XCTAssertEqual(total, 4)
        XCTAssertFalse(hasMore)
    }

    func testPagingOffsetBeyondEndReturnsEmptyPageWithTotal() {
        let (page, total, hasMore) = MailSearchPaging.page(matchedUIDs: [101, 102], offset: 5, limit: 10)
        XCTAssertTrue(page.isEmpty)
        XCTAssertEqual(total, 2)
        XCTAssertFalse(hasMore)
    }

    func testPagingRejectsNonPositiveLimitAndNegativeOffset() {
        XCTAssertTrue(MailSearchPaging.page(matchedUIDs: [1, 2, 3], offset: 0, limit: 0).page.isEmpty)
        XCTAssertTrue(MailSearchPaging.page(matchedUIDs: [1, 2, 3], offset: -1, limit: 10).page.isEmpty)
    }

    // MARK: - Criteria (pure)

    func testEmptyCriteriaIsEmpty() {
        XCTAssertTrue(MailSearchCriteria().isEmpty)
        XCTAssertTrue(MailSearchCriteria(text: "   ").isEmpty)
    }

    func testCriteriaWithAnyFilterIsNotEmpty() {
        XCTAssertFalse(MailSearchCriteria(text: "hi").isEmpty)
        XCTAssertFalse(MailSearchCriteria(readState: .unreadOnly).isEmpty)
        XCTAssertFalse(MailSearchCriteria(flaggedOnly: true).isEmpty)
        XCTAssertFalse(MailSearchCriteria(maximumUID: 123).isEmpty)
        XCTAssertFalse(MailSearchCriteria(headers: [
            MailHeaderSearch(field: "In-Reply-To", value: "orig@example.com")
        ]).isEmpty)
    }

    // MARK: - State machine

    func testSearchReturnsPagedEnvelopesNewestFirst() throws {
        let (channel, future) = try makeChannel(offset: 0, limit: 2)

        try advanceThroughSelect(channel)
        try feed(channel, "* SEARCH 101 102 103\r\n")
        try feed(channel, "A3 OK SEARCH completed\r\n")
        // Handler should now FETCH the newest two UIDs (103, 102).
        try feed(channel, envelope(uid: 103, seq: 3, subject: "Newest", from: "c"))
        try feed(channel, envelope(uid: 102, seq: 2, subject: "Middle", from: "b"))
        try feed(channel, "A4 OK FETCH completed\r\n")

        let result = try future.wait()
        XCTAssertEqual(result.messages.map(\.id), [103, 102])
        XCTAssertEqual(result.messages[0].subject, "Newest")
        XCTAssertEqual(result.messages[0].uidValidity, 123456)
        XCTAssertEqual(result.totalMatches, 3)
        XCTAssertEqual(result.offset, 0)
        XCTAssertTrue(result.hasMore)
        _ = try? channel.finish()
    }

    func testHeaderCriteriaEncodedIntoUidSearchCommand() throws {
        let criteria = MailSearchCriteria(headers: [
            MailHeaderSearch(field: "In-Reply-To", value: "orig@example.com")
        ])
        let (channel, _) = try makeChannel(criteria: criteria)

        let searchCommand = try advanceThroughSelect(channel)

        XCTAssertTrue(searchCommand.contains("UID SEARCH"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("HEADER"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("In-Reply-To"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("orig@example.com"), "got: \(searchCommand)")
        _ = try? channel.finish()
    }

    func testSecondPageReportsNoMore() throws {
        let (channel, future) = try makeChannel(offset: 2, limit: 2)

        try advanceThroughSelect(channel)
        try feed(channel, "* SEARCH 101 102 103\r\n")
        try feed(channel, "A3 OK SEARCH completed\r\n")
        // sortedDesc = [103,102,101]; offset 2 → [101].
        try feed(channel, envelope(uid: 101, seq: 1, subject: "Oldest", from: "a"))
        try feed(channel, "A4 OK FETCH completed\r\n")

        let result = try future.wait()
        XCTAssertEqual(result.messages.map(\.id), [101])
        XCTAssertEqual(result.totalMatches, 3)
        XCTAssertEqual(result.offset, 2)
        XCTAssertFalse(result.hasMore)
        _ = try? channel.finish()
    }

    func testEmptySearchResultReturnsNoMatchesAndSkipsFetch() throws {
        let (channel, future) = try makeChannel()

        try advanceThroughSelect(channel)
        try feed(channel, "* SEARCH\r\n")
        try feed(channel, "A3 OK SEARCH completed\r\n")

        let result = try future.wait()
        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertEqual(result.totalMatches, 0)
        XCTAssertFalse(result.hasMore)
        _ = try? channel.finish()
    }

    func testOffsetBeyondMatchesReturnsEmptyPageWithTotal() throws {
        let (channel, future) = try makeChannel(offset: 10, limit: 5)

        try advanceThroughSelect(channel)
        try feed(channel, "* SEARCH 101 102\r\n")
        try feed(channel, "A3 OK SEARCH completed\r\n")

        let result = try future.wait()
        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertEqual(result.totalMatches, 2)
        XCTAssertEqual(result.offset, 10)
        XCTAssertFalse(result.hasMore)
        _ = try? channel.finish()
    }

    func testCriteriaEncodedIntoUidSearchCommand() throws {
        let criteria = MailSearchCriteria(
            text: "invoice",
            from: "alice@example.com",
            since: Date(timeIntervalSince1970: 1_768_435_200),  // 2026-01-15 UTC
            readState: .unreadOnly,
            flaggedOnly: true,
            maximumUID: 500
        )
        let (channel, _) = try makeChannel(criteria: criteria)

        let searchCommand = try advanceThroughSelect(channel)

        XCTAssertTrue(searchCommand.contains("UID SEARCH"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("TEXT"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("invoice"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("FROM"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("alice@example.com"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("UNSEEN"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("FLAGGED"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("SINCE"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("UID 1:500"), "got: \(searchCommand)")
        _ = try? channel.finish()
    }

    func testDateCriteriaUsesCurrentCalendarDay() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 10 * 60 * 60))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let selectedDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 20
        )))
        let (channel, _) = try makeChannel(criteria: MailSearchCriteria(
            since: selectedDate,
            before: selectedDate
        ), calendar: calendar)

        let searchCommand = try advanceThroughSelect(channel)

        XCTAssertTrue(searchCommand.contains("SINCE 20-Jul-2026"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("BEFORE 20-Jul-2026"), "got: \(searchCommand)")
        XCTAssertFalse(searchCommand.contains("19-Jul-2026"), "got: \(searchCommand)")
        _ = try? channel.finish()
    }

    func testDateCriteriaUsesGregorianYearWithInjectedTimeZone() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 10 * 60 * 60))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let selectedDate = try XCTUnwrap(gregorian.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 20
        )))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = timeZone
        let (channel, _) = try makeChannel(criteria: MailSearchCriteria(
            since: selectedDate,
            before: selectedDate
        ), calendar: buddhist)

        let searchCommand = try advanceThroughSelect(channel)

        XCTAssertTrue(searchCommand.contains("SINCE 20-Jul-2026"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("BEFORE 20-Jul-2026"), "got: \(searchCommand)")
        XCTAssertFalse(searchCommand.contains("2569"), "got: \(searchCommand)")
        XCTAssertFalse(searchCommand.contains("19-Jul-2026"), "got: \(searchCommand)")
        _ = try? channel.finish()
    }

    func testEmptyCriteriaSearchesAll() throws {
        let (channel, _) = try makeChannel()
        let searchCommand = try advanceThroughSelect(channel)
        XCTAssertTrue(searchCommand.contains("UID SEARCH"), "got: \(searchCommand)")
        XCTAssertTrue(searchCommand.contains("ALL"), "got: \(searchCommand)")
        _ = try? channel.finish()
    }

    func testAllMailMapsToGmailPath() {
        XCTAssertEqual(Mailbox.allMail.imapName, "[Gmail]/All Mail")
    }

    func testSelectsTheRequestedMailbox() throws {
        let (channel, _) = try makeChannel(mailbox: Mailbox.allMail.imapName)

        try feed(channel, "* OK Service Ready\r\n")
        let selectCommand = try feed(channel, "A1 OK LOGIN completed\r\n")

        XCTAssertTrue(selectCommand.contains("SELECT"), "got: \(selectCommand)")
        XCTAssertTrue(selectCommand.contains("All Mail"), "got: \(selectCommand)")
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

    func testSearchFailureSurfacesCommandError() throws {
        let (channel, future) = try makeChannel()

        try advanceThroughSelect(channel)
        try feed(channel, "A3 BAD Invalid search program\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .commandFailed = error as? MailError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
        }
        _ = try? channel.finish()
    }

    // MARK: - Oversized result (item 45)

    func testPayloadTooLargeMapsToResultTooLarge() {
        XCTAssertEqual(
            IMAPSearchHandler.mapped(ByteToMessageDecoderError.PayloadTooLargeError()),
            .resultTooLarge
        )
    }

    func testOtherErrorsStayConnectionFailures() {
        guard case .connectionFailed = IMAPSearchHandler.mapped(MailError.commandFailed("x")) else {
            return XCTFail("non-overflow errors must remain connectionFailed")
        }
    }

    /// A huge mailbox answers an unbounded UID SEARCH with a `* SEARCH …` line
    /// past NIO-IMAP's 8 KB frame cap; the decoder reports that as a
    /// `PayloadTooLargeError`. This is what the user hit live on att.net, so the
    /// handler must fail the search with the actionable `.resultTooLarge` rather
    /// than a generic connection error — and must not leave the caller hanging.
    func testDecoderOverflowFailsSearchWithResultTooLarge() throws {
        let (channel, future) = try makeChannel()
        try advanceThroughSelect(channel)

        channel.pipeline.fireErrorCaught(ByteToMessageDecoderError.PayloadTooLargeError())

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .resultTooLarge = error as? MailError else {
                return XCTFail("expected resultTooLarge, got \(error)")
            }
        }
        _ = try? channel.finish()
    }
}
