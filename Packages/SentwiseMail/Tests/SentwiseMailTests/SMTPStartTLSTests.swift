import NIOCore
import NIOEmbedded
import XCTest
@testable import SentwiseMail

/// A pass-through stand-in for the NIOSSL handler, so the STARTTLS state machine
/// can be driven over an `EmbeddedChannel` with no network (item 31, T31-6).
private final class FakeTLSHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
}

private struct TLSInsertFailure: Error {}

final class SMTPStartTLSTests: XCTestCase {

    private let rfc822 = "Subject: Hi\r\n\r\nHello.\r\n".data(using: .utf8)!

    private func makeChannel(
        authentication: MailAuthentication = .xoauth2(accessToken: "tok"),
        tlsFactory: @escaping () throws -> ChannelHandler = { FakeTLSHandler() }
    ) throws -> (EmbeddedChannel, EventLoopFuture<Void>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let handler = SMTPSendHandler(
            email: "me@contoso.com",
            authentication: authentication,
            senderDomain: "contoso.com",
            envelope: SMTPEnvelope(sender: "me@contoso.com", recipients: ["a@example.com"]),
            message: ByteBuffer(bytes: rfc822),
            security: .startTLS,
            makeTLSHandler: tlsFactory,
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([
            ByteToMessageHandler(SMTPResponseDecoder()),
            handler
        ])
        return (channel, promise.futureResult)
    }

    @discardableResult
    private func feed(_ channel: EmbeddedChannel, _ reply: String) throws -> String {
        try channel.writeInbound(ByteBuffer(string: reply))
        var out = ""
        while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
            out += String(buffer: buffer)
        }
        return out
    }

    private func mailError(_ future: EventLoopFuture<Void>) -> MailError? {
        do { try future.wait(); return nil } catch { return error as? MailError }
    }

    func testStartTLSUpgradesThenReissuesEHLOThenAuthenticates() throws {
        let (channel, _) = try makeChannel()

        XCTAssertTrue(try feed(channel, "220 smtp.office365.com ESMTP\r\n").contains("EHLO contoso.com"))

        let starttls = try feed(channel, "250-smtp.office365.com\r\n250-SIZE 157286400\r\n250 STARTTLS\r\n")
        XCTAssertEqual(starttls.trimmingCharacters(in: .whitespacesAndNewlines), "STARTTLS")

        XCTAssertNil(try? channel.pipeline.syncOperations.handler(type: FakeTLSHandler.self))
        let ehlo2 = try feed(channel, "220 2.0.0 SMTP server ready\r\n")
        XCTAssertTrue(ehlo2.contains("EHLO contoso.com"), "EHLO must be re-issued after the upgrade: \(ehlo2)")
        XCTAssertNotNil(try? channel.pipeline.syncOperations.handler(type: FakeTLSHandler.self), "TLS handler not inserted")

        let auth = try feed(channel, "250-smtp.office365.com\r\n250 AUTH LOGIN XOAUTH2\r\n")
        XCTAssertTrue(auth.hasPrefix("AUTH XOAUTH2 "), "got: \(auth)")

        let mailFrom = try feed(channel, "235 2.7.0 Authentication successful\r\n")
        XCTAssertTrue(mailFrom.contains("MAIL FROM:<me@contoso.com>"))
        _ = try? channel.finish()
    }

    func testServerWithoutSTARTTLSRefusesAuthWithTypedError() throws {
        let (channel, future) = try makeChannel()
        try feed(channel, "220 ready\r\n")
        let out = try feed(channel, "250-host\r\n250 AUTH LOGIN XOAUTH2\r\n")
        XCTAssertFalse(out.contains("AUTH"), "AUTH must not be sent without STARTTLS: \(out)")
        XCTAssertEqual(mailError(future), .starttlsNotOffered)
        _ = try? channel.finish()
    }

    func testSTARTTLSRejectedByServerFailsWithTypedError() throws {
        let (channel, future) = try makeChannel()
        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 STARTTLS\r\n")
        let out = try feed(channel, "454 4.7.0 TLS not available\r\n")
        XCTAssertFalse(out.contains("AUTH"))
        guard case .starttlsFailed(let detail)? = mailError(future) else {
            return XCTFail("expected starttlsFailed")
        }
        XCTAssertTrue(detail.contains("454"))
        _ = try? channel.finish()
    }

    func testUpgradeFailureFailsWithTypedErrorAndNeverAuthenticates() throws {
        let (channel, future) = try makeChannel(tlsFactory: { throw TLSInsertFailure() })
        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 STARTTLS\r\n")
        let out = try feed(channel, "220 go ahead\r\n")
        XCTAssertFalse(out.contains("AUTH"))
        guard case .starttlsFailed? = mailError(future) else { return XCTFail("expected starttlsFailed") }
        _ = try? channel.finish()
    }

    func testHandshakeErrorAfterUpgradeSurfacesAsStartTLSFailed() throws {
        let (channel, future) = try makeChannel()
        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 STARTTLS\r\n")
        try feed(channel, "220 go ahead\r\n")
        channel.pipeline.fireErrorCaught(TLSInsertFailure())
        guard case .starttlsFailed? = mailError(future) else { return XCTFail("expected starttlsFailed") }
        _ = try? channel.finish()
    }

    func testSMTPAuthDisabledMapsToMailboxProtocolDisabled() throws {
        let (channel, future) = try makeChannel()
        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 STARTTLS\r\n")
        try feed(channel, "220 go\r\n")
        try feed(channel, "250 AUTH XOAUTH2\r\n")
        try feed(channel, "535 5.7.139 Authentication unsuccessful, SmtpClientAuthentication is disabled for the Tenant.\r\n")
        guard case .mailboxProtocolDisabled? = mailError(future) else {
            return XCTFail("expected mailboxProtocolDisabled")
        }
        _ = try? channel.finish()
    }

    func testImplicitTLSPathIsUnchangedAndDoesNotNeedSTARTTLS() throws {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let handler = SMTPSendHandler(
            email: "me@gmail.com",
            authentication: .password("pw"),
            senderDomain: "gmail.com",
            envelope: SMTPEnvelope(sender: "me@gmail.com", recipients: ["a@example.com"]),
            message: ByteBuffer(bytes: rfc822),
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([ByteToMessageHandler(SMTPResponseDecoder()), handler])
        try feed(channel, "220 ready\r\n")
        let auth = try feed(channel, "250 AUTH LOGIN\r\n")
        XCTAssertTrue(auth.contains("AUTH LOGIN"), "got: \(auth)")
        _ = try? channel.finish()
    }

    func testCredentialsDefaultToImplicitTLS() {
        let creds = MailAccountCredentials(email: "a@b.com", appPassword: "x")
        XCTAssertEqual(creds.smtpSecurity, .implicitTLS)
        XCTAssertEqual(creds.smtpPort, 465)
    }
}
