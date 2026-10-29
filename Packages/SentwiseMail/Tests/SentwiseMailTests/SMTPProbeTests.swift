import NIOCore
import NIOEmbedded
import NIOSSL
import NIOTLS
import XCTest
@testable import SentwiseMail

private final class ProbeFakeTLSHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
}

/// Scripted SMTP AUTH-only probe (item 31, T31-7). No network.
final class SMTPProbeTests: XCTestCase {

    private func makeChannel() throws -> (EmbeddedChannel, EventLoopFuture<Void>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let decoder = SMTPResponseDecoder()
        let handler = SMTPSendHandler(
            email: "me@contoso.com",
            authentication: .xoauth2(accessToken: "tok"),
            senderDomain: "contoso.com",
            envelope: SMTPEnvelope(sender: "me@contoso.com", recipients: []),
            message: ByteBuffer(),
            security: .startTLS,
            makeTLSHandler: { ProbeFakeTLSHandler() },
            decoder: decoder,
            authenticateOnly: true,
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([ByteToMessageHandler(decoder), handler])
        return (channel, promise.futureResult)
    }

    @discardableResult
    private func feed(_ channel: EmbeddedChannel, _ reply: String) throws -> String {
        try channel.writeInbound(ByteBuffer(string: reply))
        return drain(channel)
    }

    private func drain(_ channel: EmbeddedChannel) -> String {
        var out = ""
        while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
            out += String(buffer: buffer)
        }
        return out
    }

    private func reachAuth(_ channel: EmbeddedChannel) throws -> String {
        try feed(channel, "220 smtp ESMTP\r\n")
        try feed(channel, "250 STARTTLS\r\n")
        try feed(channel, "220 go ahead\r\n")
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil))
        _ = drain(channel)
        return try feed(channel, "250 AUTH XOAUTH2\r\n")
    }

    private func mailError(_ future: EventLoopFuture<Void>) -> MailError? {
        do { try future.wait(); return nil } catch { return error as? MailError }
    }

    func testProbeSucceedsAfterAuthWithoutSendingMail() throws {
        let (channel, future) = try makeChannel()
        let auth = try reachAuth(channel)
        XCTAssertTrue(auth.hasPrefix("AUTH XOAUTH2 "), "got: \(auth)")
        let after = try feed(channel, "235 2.7.0 Authentication successful\r\n")
        XCTAssertFalse(after.contains("MAIL FROM"), "probe must not start a message: \(after)")
        XCTAssertTrue(after.contains("QUIT"))
        XCTAssertNil(mailError(future))
        _ = try? channel.finish()
    }

    func testProbeMapsSMTPAuthDisabledToProtocolDisabled() throws {
        let (channel, future) = try makeChannel()
        _ = try reachAuth(channel)
        try feed(
            channel,
            "535 5.7.139 Authentication unsuccessful, SmtpClientAuthentication is disabled for the Tenant.\r\n"
        )
        guard case .mailboxProtocolDisabled(let proto, _)? = mailError(future) else {
            return XCTFail("expected mailboxProtocolDisabled")
        }
        XCTAssertEqual(proto, .smtp)
        _ = try? channel.finish()
    }
}
