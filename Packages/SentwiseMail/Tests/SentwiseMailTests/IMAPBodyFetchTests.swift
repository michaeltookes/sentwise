import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import SentwiseMail

/// Drives `IMAPBodyFetchHandler` through the real IMAP decoder with an
/// `EmbeddedChannel`, feeding raw server responses — deterministic coverage of
/// the LOGIN → SELECT → UID FETCH (BODY.PEEK[TEXT]) state machine and the
/// streaming body assembly, no server.
final class IMAPBodyFetchTests: XCTestCase {

    private func makeChannel(
        uid: UInt32 = 101,
        mailbox: String = "INBOX",
        expectedUIDValidity: UInt32? = nil
    ) throws -> (EmbeddedChannel, EventLoopFuture<Data>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Data.self)
        let handler = IMAPBodyFetchHandler(
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

    private func feed(_ channel: EmbeddedChannel, _ response: String) throws {
        try channel.writeInbound(ByteBuffer(string: response))
        while (try? channel.readOutbound(as: ByteBuffer.self)) != nil {}
    }

    private func feed(_ channel: EmbeddedChannel, bytes: [UInt8]) throws {
        try channel.writeInbound(ByteBuffer(bytes: bytes))
        while (try? channel.readOutbound(as: ByteBuffer.self)) != nil {}
    }

    func testAssemblesStreamedBodyText() throws {
        let (channel, future) = try makeChannel()
        let body = "Hi Alice,\r\n\r\nThanks for the update.\r\n\r\n— Me"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* 3 EXISTS\r\n")
        try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")
        try feed(channel, "* 1 FETCH (UID 101 BODY[TEXT] {\(body.utf8.count)}\r\n\(body))\r\n")
        try feed(channel, "A3 OK FETCH completed\r\n")

        XCTAssertEqual(try future.wait(), Data(body.utf8))
        _ = try? channel.finish()
    }

    func testBodyStreamedInMultipleChunks() throws {
        let (channel, future) = try makeChannel()
        // A literal split across two inbound reads must still assemble intact.
        let body = "The quick brown fox jumps over the lazy dog."
        let head = "* 1 FETCH (UID 101 BODY[TEXT] {\(body.utf8.count)}\r\n"

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, head)
        try feed(channel, String(body.prefix(10)))
        try feed(channel, String(body.dropFirst(10)))
        try feed(channel, ")\r\n")
        try feed(channel, "A3 OK FETCH completed\r\n")

        XCTAssertEqual(try future.wait(), Data(body.utf8))
        _ = try? channel.finish()
    }

    func testPreservesNonUTF8BodyBytes() throws {
        let (channel, future) = try makeChannel()
        let body = Array("Content-Type: text/plain; charset=iso-8859-1\r\n\r\nCaf".utf8) + [0xE9]

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, "* 1 FETCH (UID 101 BODY[TEXT] {\(body.count)}\r\n")
        try feed(channel, bytes: body)
        try feed(channel, ")\r\n")
        try feed(channel, "A3 OK FETCH completed\r\n")

        XCTAssertEqual(try future.wait(), Data(body))
        _ = try? channel.finish()
    }

    func testFetchOKWithoutBodySurfacesCommandError() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        try feed(channel, "A3 OK FETCH completed\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            XCTAssertEqual(
                error as? MailError,
                .commandFailed("No body was returned for the selected message.")
            )
        }
        _ = try? channel.finish()
    }

    func testUIDValidityMismatchSurfacesCommandErrorBeforeFetchingBody() throws {
        let (channel, future) = try makeChannel(expectedUIDValidity: 123)

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* OK [UIDVALIDITY 456] UIDs valid\r\n")
        try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            XCTAssertEqual(
                error as? MailError,
                .commandFailed("The mailbox changed before the message body was fetched.")
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
