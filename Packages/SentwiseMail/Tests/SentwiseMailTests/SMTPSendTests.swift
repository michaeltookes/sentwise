import NIOCore
import NIOEmbedded
import XCTest
@testable import SentwiseMail

/// Drives `SMTPSendHandler` (behind the real `SMTPResponseDecoder`) through an
/// `EmbeddedChannel`, exercising the greeting → EHLO → AUTH → MAIL/RCPT → DATA
/// exchange without a live server.
final class SMTPSendTests: XCTestCase {

    private let rfc822 = "Subject: Hi\r\n\r\nHello there.\r\n".data(using: .utf8)!

    private func makeChannel(
        envelope: SMTPEnvelope = SMTPEnvelope(sender: "me@gmail.com", recipients: ["alice@example.com"])
    ) throws -> (EmbeddedChannel, EventLoopFuture<Void>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let handler = SMTPSendHandler(
            email: "me@gmail.com",
            password: "app-pw",
            senderDomain: "gmail.com",
            envelope: envelope,
            message: ByteBuffer(bytes: rfc822),
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([
            ByteToMessageHandler(SMTPResponseDecoder()),
            handler
        ])
        return (channel, promise.futureResult)
    }

    /// Feeds inbound bytes and returns the concatenated outbound bytes produced.
    @discardableResult
    private func feed(_ channel: EmbeddedChannel, _ reply: String) throws -> String {
        try channel.writeInbound(ByteBuffer(string: reply))
        var out = ""
        while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
            out += String(buffer: buffer)
        }
        return out
    }

    func testFullSendExchangeCompletes() throws {
        let (channel, future) = try makeChannel()

        let ehlo = try feed(channel, "220 smtp.gmail.com ESMTP ready\r\n")
        XCTAssertTrue(ehlo.contains("EHLO gmail.com"), "got: \(ehlo)")

        let auth = try feed(channel, "250-smtp.gmail.com at your service\r\n250 AUTH LOGIN PLAIN\r\n")
        XCTAssertTrue(auth.contains("AUTH LOGIN"), "got: \(auth)")

        let username = try feed(channel, "334 VXNlcm5hbWU6\r\n")
        XCTAssertEqual(username.trimmingCharacters(in: .whitespacesAndNewlines),
                       Data("me@gmail.com".utf8).base64EncodedString())

        let passwordSent = try feed(channel, "334 UGFzc3dvcmQ6\r\n")
        XCTAssertEqual(passwordSent.trimmingCharacters(in: .whitespacesAndNewlines),
                       Data("app-pw".utf8).base64EncodedString())

        let mailFrom = try feed(channel, "235 2.7.0 Accepted\r\n")
        XCTAssertTrue(mailFrom.contains("MAIL FROM:<me@gmail.com>"), "got: \(mailFrom)")

        let rcpt = try feed(channel, "250 2.1.0 OK\r\n")
        XCTAssertTrue(rcpt.contains("RCPT TO:<alice@example.com>"), "got: \(rcpt)")

        let data = try feed(channel, "250 2.1.5 OK\r\n")
        XCTAssertTrue(data.contains("DATA"), "got: \(data)")

        let body = try feed(channel, "354 Go ahead\r\n")
        XCTAssertTrue(body.contains("Hello there."), "message body not sent: \(body)")
        XCTAssertTrue(body.hasSuffix(".\r\n"), "DATA not terminated with dot: \(body)")

        let quit = try feed(channel, "250 2.0.0 OK queued\r\n")
        XCTAssertTrue(quit.contains("QUIT"), "got: \(quit)")

        XCTAssertNoThrow(try future.wait())
        _ = try? channel.finish()
    }

    func testMultipleRecipientsEachGetRcpt() throws {
        let (channel, future) = try makeChannel(
            envelope: SMTPEnvelope(sender: "me@gmail.com", recipients: ["a@x.com", "b@y.com"])
        )

        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 ok\r\n")
        try feed(channel, "334 VXNlcm5hbWU6\r\n")
        try feed(channel, "334 UGFzc3dvcmQ6\r\n")
        try feed(channel, "235 accepted\r\n")
        let firstRcpt = try feed(channel, "250 ok\r\n")
        XCTAssertTrue(firstRcpt.contains("RCPT TO:<a@x.com>"), "got: \(firstRcpt)")
        let secondRcpt = try feed(channel, "250 ok\r\n")
        XCTAssertTrue(secondRcpt.contains("RCPT TO:<b@y.com>"), "got: \(secondRcpt)")
        let data = try feed(channel, "250 ok\r\n")
        XCTAssertTrue(data.contains("DATA"), "got: \(data)")

        try feed(channel, "354 go\r\n")
        try feed(channel, "250 queued\r\n")
        XCTAssertNoThrow(try future.wait())
        _ = try? channel.finish()
    }

    func testAuthFailureSurfacesAuthenticationError() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 ok\r\n")
        try feed(channel, "334 VXNlcm5hbWU6\r\n")
        try feed(channel, "334 UGFzc3dvcmQ6\r\n")
        try feed(channel, "535 5.7.8 Username and Password not accepted\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .authenticationFailed = error as? MailError else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
        _ = try? channel.finish()
    }

    func testTemporaryAuthFailurePreservesStatusCode() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 ok\r\n")
        try feed(channel, "454 4.7.0 Temporary authentication failure\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .smtpCommandFailed(let code, let message) = error as? MailError else {
                return XCTFail("expected smtpCommandFailed, got \(error)")
            }
            XCTAssertEqual(code, 454)
            XCTAssertTrue(message.contains("Temporary authentication failure"))
        }
        _ = try? channel.finish()
    }

    func testRejectedRecipientSurfacesCommandError() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 ok\r\n")
        try feed(channel, "334 VXNlcm5hbWU6\r\n")
        try feed(channel, "334 UGFzc3dvcmQ6\r\n")
        try feed(channel, "235 accepted\r\n")
        try feed(channel, "250 ok\r\n")           // MAIL FROM
        try feed(channel, "550 No such user\r\n") // RCPT TO rejected

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .smtpCommandFailed(let code, _) = error as? MailError else {
                return XCTFail("expected smtpCommandFailed, got \(error)")
            }
            XCTAssertEqual(code, 550)
        }
        _ = try? channel.finish()
    }

    func testTemporarySMTPReplyPreservesStatusCode() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "220 ready\r\n")
        try feed(channel, "421 Service not available\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .smtpCommandFailed(let code, let message) = error as? MailError else {
                return XCTFail("expected smtpCommandFailed, got \(error)")
            }
            XCTAssertEqual(code, 421)
            XCTAssertTrue(message.contains("Service not available"))
        }
        _ = try? channel.finish()
    }

    // MARK: - Send-failure phase classification (item 27 no-duplicate-sends)

    /// A connection drop *before* the DATA body is written is safe to retry: the
    /// server never received the message, so it surfaces as `connectionFailed`.
    func testConnectionDropBeforeDataIsRetryableConnectionFailure() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 ok\r\n")
        try feed(channel, "334 VXNlcm5hbWU6\r\n")
        // Drop the connection mid-AUTH, before any DATA submission.
        _ = try channel.finish() // fires channelInactive

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .connectionFailed = error as? MailError else {
                return XCTFail("expected connectionFailed (retryable), got \(error)")
            }
        }
    }

    /// A connection drop *after* the DATA body is submitted is ambiguous — the
    /// server may have queued the message — so it surfaces as
    /// `sendInterruptedAfterSubmission` and must never be auto-retried.
    func testConnectionDropAfterDataIsAmbiguousAndNotRetryable() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 ok\r\n")
        try feed(channel, "334 VXNlcm5hbWU6\r\n")
        try feed(channel, "334 UGFzc3dvcmQ6\r\n")
        try feed(channel, "235 accepted\r\n")
        try feed(channel, "250 ok\r\n") // MAIL FROM
        try feed(channel, "250 ok\r\n") // RCPT TO
        let body = try feed(channel, "354 go ahead\r\n")
        XCTAssertTrue(body.contains("Hello there."), "message body not sent: \(body)")

        // The connection closes before the final 250 acknowledging the message.
        _ = try channel.finish() // fires channelInactive after DATA submission

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .sendInterruptedAfterSubmission = error as? MailError else {
                return XCTFail("expected sendInterruptedAfterSubmission (ambiguous), got \(error)")
            }
        }
    }

    /// An explicit non-250 reply *after* DATA is a definitive server rejection
    /// (the message was not queued), so it stays a `commandFailed`, distinct from
    /// the ambiguous connection-drop case.
    func testExplicitRejectionAfterDataStaysCommandFailure() throws {
        let (channel, future) = try makeChannel()

        try feed(channel, "220 ready\r\n")
        try feed(channel, "250 ok\r\n")
        try feed(channel, "334 VXNlcm5hbWU6\r\n")
        try feed(channel, "334 UGFzc3dvcmQ6\r\n")
        try feed(channel, "235 accepted\r\n")
        try feed(channel, "250 ok\r\n")
        try feed(channel, "250 ok\r\n")
        try feed(channel, "354 go ahead\r\n")
        try feed(channel, "552 5.3.4 Message too big\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .smtpCommandFailed(let code, _) = error as? MailError else {
                return XCTFail("expected smtpCommandFailed, got \(error)")
            }
            XCTAssertEqual(code, 552)
        }
        _ = try? channel.finish()
    }

    func testDotStuffingEscapesLeadingDots() {
        let message = ByteBuffer(string: ".hidden\r\nnormal\r\n..two\r\n")
        let stuffed = String(buffer: SMTPSendHandler.dotStuffed(message))
        XCTAssertEqual(stuffed, "..hidden\r\nnormal\r\n...two\r\n")
    }

    func testDomainExtraction() {
        XCTAssertEqual(SMTPSendHandler.domain(of: "me@gmail.com"), "gmail.com")
        XCTAssertEqual(SMTPSendHandler.domain(of: ""), "localhost")
    }

    func testDerivedSMTPHost() {
        XCTAssertEqual(MailAccountCredentials.derivedSMTPHost(from: "imap.gmail.com"), "smtp.gmail.com")
        XCTAssertEqual(MailAccountCredentials.derivedSMTPHost(from: "mail.fastmail.com"), "mail.fastmail.com")
    }
}
