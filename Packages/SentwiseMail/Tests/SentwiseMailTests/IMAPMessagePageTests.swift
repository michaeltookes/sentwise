import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import SentwiseMail

/// Drives `IMAPMessagePageHandler` through the real IMAP decoder with an
/// `EmbeddedChannel`, feeding raw server responses — deterministic coverage of
/// bounded sequence-page fetching, no server.
final class IMAPMessagePageTests: XCTestCase {

    private func makeChannel(
        offset: Int,
        limit: Int,
        snapshotMessageCount: Int? = nil
    ) throws -> (EmbeddedChannel, EventLoopFuture<MailSearchResult>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: MailSearchResult.self)
        let handler = IMAPMessagePageHandler(
            email: "me@gmail.com",
            password: "pw",
            mailboxName: "INBOX",
            offset: offset,
            limit: limit,
            snapshotMessageCount: snapshotMessageCount,
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

    private func envelope(uid: UInt32, seq: UInt32) -> String {
        "* \(seq) FETCH (UID \(uid) ENVELOPE (\"Wed, 1 Jan 2026 10:00:00 +0000\" "
            + "\"Subject \(uid)\" ((\"Sender\" NIL \"sender\" \"example.com\")) "
            + "NIL NIL NIL NIL NIL NIL \"<\(uid)@example.com>\"))\r\n"
    }

    func testSnapshotMessageCountKeepsNextSequencePageStableWhenNewMessagesArrive() throws {
        let (channel, future) = try makeChannel(offset: 25, limit: 25, snapshotMessageCount: 30)

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* 31 EXISTS\r\n")
        let fetchCommand = try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")

        XCTAssertTrue(fetchCommand.contains("FETCH 1:5"), "got: \(fetchCommand)")

        for uid in [104, 103, 102, 101, 100] {
            try feed(channel, envelope(uid: UInt32(uid), seq: UInt32(uid - 99)))
        }
        try feed(channel, "A3 OK FETCH completed\r\n")

        let result = try future.wait()
        XCTAssertEqual(result.messages.map(\.id), [104, 103, 102, 101, 100])
        XCTAssertEqual(result.totalMatches, 30)
        XCTAssertEqual(result.offset, 25)
        XCTAssertFalse(result.hasMore)
        _ = try? channel.finish()
    }
}
