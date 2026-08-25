import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import SentwiseMail

/// Drives `IMAPFetchHandler` through the real IMAP decoder with an
/// `EmbeddedChannel`, feeding raw server responses — deterministic coverage of
/// the LOGIN → SELECT → FETCH state machine and envelope parsing, no server.
final class IMAPFetchTests: XCTestCase {

    private func makeChannel(
        limit: Int = 50,
        mailbox: String = "INBOX"
    ) throws -> (EmbeddedChannel, EventLoopFuture<[MailMessage]>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: [MailMessage].self)
        let handler = IMAPFetchHandler(
            email: "me@gmail.com",
            password: "pw",
            mailboxName: mailbox,
            limit: limit,
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([IMAPClientHandler(), handler])
        return (channel, promise.futureResult)
    }

    private func feed(_ channel: EmbeddedChannel, _ response: String) throws {
        try channel.writeInbound(ByteBuffer(string: response))
        while (try? channel.readOutbound(as: ByteBuffer.self)) != nil {}
    }

    func testFetchesAndParsesEnvelopesSortedByNewestUID() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* 2 EXISTS\r\n")
        try feed(channel, "* OK [UIDVALIDITY 123456] UIDs valid\r\n")
        try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")
        try feed(channel, "* 2 FETCH (UID 102 ENVELOPE (\"Thu, 2 Jan 2026 10:00:00 +0000\" "
            + "\"World\" ((\"Bob\" NIL \"bob\" \"example.com\")) NIL "
            + "((\"Team Inbox\" NIL \"team\" \"example.net\")) "
            + "((\"Alice\" NIL \"alice\" \"example.com\")) NIL NIL \"<hello@example.com>\" "
            + "\"<world@example.com>\"))\r\n")
        try feed(channel, "* 1 FETCH (UID 101 ENVELOPE (\"Wed, 1 Jan 2026 10:00:00 +0000\" "
            + "\"Hello\" ((\"Alice\" NIL \"alice\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n")
        try feed(channel, "A3 OK FETCH completed\r\n")

        let messages = try future.wait()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].id, 102)
        XCTAssertEqual(messages[0].uidValidity, 123456)
        XCTAssertEqual(messages[0].subject, "World")
        XCTAssertEqual(messages[0].from, MailAddress(name: "Bob", email: "bob@example.com"))
        XCTAssertEqual(messages[0].replyTo, MailAddress(name: "Team Inbox", email: "team@example.net"))
        XCTAssertEqual(messages[0].to, [MailAddress(name: "Alice", email: "alice@example.com")])
        XCTAssertEqual(messages[0].inReplyTo, "<hello@example.com>")
        XCTAssertEqual(messages[0].messageID, "<world@example.com>")
        XCTAssertNil(messages[1].messageID)
        XCTAssertEqual(messages[1].id, 101)
        XCTAssertEqual(messages[1].uidValidity, 123456)
        XCTAssertEqual(messages[1].subject, "Hello")
        XCTAssertEqual(messages[1].from, MailAddress(name: "Alice", email: "alice@example.com"))
        XCTAssertNil(messages[1].replyTo)
        _ = try? channel.finish()
    }

    func testIgnoresUnsolicitedFetchResponsesWithoutEnvelope() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* 1 EXISTS\r\n")
        try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")
        try feed(channel, "* 1 FETCH (FLAGS (\\Seen))\r\n")
        try feed(channel, "* 1 FETCH (UID 101 ENVELOPE (\"Wed, 1 Jan 2026 10:00:00 +0000\" "
            + "\"Hello\" ((\"Alice\" NIL \"alice\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n")
        try feed(channel, "A3 OK FETCH completed\r\n")

        let messages = try future.wait()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].id, 101)
        XCTAssertEqual(messages[0].subject, "Hello")
        _ = try? channel.finish()
    }

    func testEmptyMailboxReturnsNoMessages() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* 0 EXISTS\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")

        XCTAssertEqual(try future.wait(), [])
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
}
