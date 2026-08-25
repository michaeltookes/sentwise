import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import SentwiseMail

/// Drives `IMAPAppendHandler` through the real IMAP client handler with an
/// `EmbeddedChannel`, exercising the LOGIN → APPEND (literal + continuation) →
/// LOGOUT flow without a server.
final class IMAPAppendTests: XCTestCase {

    private let rfc822 = "Subject: Hi\r\n\r\nHello there.".data(using: .utf8)!

    private func makeChannel(
        flags: [MailFlag] = [.draft]
    ) throws -> (EmbeddedChannel, EventLoopFuture<Void>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let handler = IMAPAppendHandler(
            email: "me@gmail.com",
            password: "pw",
            mailboxName: "[Gmail]/Drafts",
            message: ByteBuffer(bytes: rfc822),
            flags: flags,
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([IMAPClientHandler(), handler])
        return (channel, promise.futureResult)
    }

    /// Feeds inbound bytes and returns the concatenated outbound bytes produced.
    @discardableResult
    private func feed(_ channel: EmbeddedChannel, _ response: String) throws -> String {
        try channel.writeInbound(ByteBuffer(string: response))
        var out = ""
        while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
            out += String(buffer: buffer)
        }
        return out
    }

    func testAppendsMessageWithDraftFlagAndCompletes() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        let appendCommand = try feed(channel, "A1 OK LOGIN completed\r\n")
        XCTAssertTrue(appendCommand.contains("A2 APPEND \"[Gmail]/Drafts\""), "got: \(appendCommand)")
        XCTAssertTrue(appendCommand.contains("\\Draft"), "draft flag missing: \(appendCommand)")
        XCTAssertTrue(appendCommand.contains("{\(rfc822.count)}"), "literal size missing: \(appendCommand)")

        // Continuation → the client handler flushes the buffered message bytes.
        let flushed = try feed(channel, "+ OK\r\n")
        XCTAssertTrue(flushed.contains("Hello there."), "message body not flushed: \(flushed)")

        try feed(channel, "A2 OK [APPENDUID 1 10] APPEND completed\r\n")
        XCTAssertNoThrow(try future.wait())
        _ = try? channel.finish()
    }

    func testAppendFailureSurfacesCommandError() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "+ OK\r\n")
        try feed(channel, "A2 NO [TRYCREATE] Mailbox doesn't exist\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .commandFailed = error as? MailError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
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
}
