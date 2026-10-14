import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import SentwiseMail

/// XOAUTH2 ("Sign in with Google", item 104): the SASL string, credential
/// selection, and the IMAP + SMTP exchanges including Gmail's error challenge.
final class XOAuth2Tests: XCTestCase {

    // MARK: - SASL string

    func testInitialResponseMatchesGoogleFormat() {
        let raw = XOAuth2.initialResponse(email: "me@gmail.com", accessToken: "ya29.token")
        XCTAssertEqual(raw, "user=me@gmail.com\u{01}auth=Bearer ya29.token\u{01}\u{01}")
    }

    func testEncodedInitialResponseIsBase64OfRaw() throws {
        let encoded = XOAuth2.encodedInitialResponse(email: "me@gmail.com", accessToken: "ya29.token")
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertEqual(String(bytes: decoded, encoding: .utf8),
                       "user=me@gmail.com\u{01}auth=Bearer ya29.token\u{01}\u{01}")
        // Google's documented example vector.
        XCTAssertEqual(
            XOAuth2.encodedInitialResponse(email: "someuser@example.com", accessToken: "ya29.vF9dft4qmTc2Nvb3RlckBhdHRhdmlzdGEuY29tCg"),
            "dXNlcj1zb21ldXNlckBleGFtcGxlLmNvbQFhdXRoPUJlYXJlciB5YTI5LnZGOWRmdDRxbVRjMk52YjNSbGNrQmhkSFJoZG1semRHRXVZMjl0Q2cBAQ=="
        )
    }

    // MARK: - Credential selection

    func testCredentialsDefaultToPasswordAuthentication() {
        let credentials = MailAccountCredentials(email: "me@gmail.com", appPassword: "pw")
        XCTAssertEqual(credentials.authentication, .password("pw"))
    }

    func testOAuthTokenSelectsXOAuth2AndSatisfiesCompleteness() {
        let credentials = MailAccountCredentials(email: "me@gmail.com", appPassword: "", oauthAccessToken: "at")
        XCTAssertEqual(credentials.authentication, .xoauth2(accessToken: "at"))
        XCTAssertTrue(credentials.isComplete)
    }

    func testEmptyOAuthTokenFallsBackToPassword() {
        let credentials = MailAccountCredentials(email: "me@gmail.com", appPassword: "pw", oauthAccessToken: "")
        XCTAssertEqual(credentials.authentication, .password("pw"))
        XCTAssertFalse(MailAccountCredentials(email: "me@gmail.com", appPassword: "", oauthAccessToken: "").isComplete)
    }

    // MARK: - IMAP

    private func makeIMAPVerifyChannel(
        authentication: MailAuthentication
    ) throws -> (EmbeddedChannel, EventLoopFuture<Void>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let handler = IMAPVerifyHandler(
            email: "me@gmail.com",
            authentication: authentication,
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([IMAPClientHandler(), handler])
        return (channel, promise.futureResult)
    }

    @discardableResult
    private func feed(_ channel: EmbeddedChannel, _ text: String) throws -> String {
        try channel.writeInbound(ByteBuffer(string: text))
        var out = ""
        while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
            out += String(buffer: buffer)
        }
        return out
    }

    func testIMAPSendsAuthenticateXOAuth2WithInitialResponse() throws {
        let (channel, future) = try makeIMAPVerifyChannel(authentication: .xoauth2(accessToken: "at"))

        let sent = try feed(channel, "* OK Gimap ready\r\n")
        let expected = XOAuth2.encodedInitialResponse(email: "me@gmail.com", accessToken: "at")
        XCTAssertEqual(sent, "A1 AUTHENTICATE XOAUTH2 \(expected)\r\n")
        XCTAssertFalse(sent.contains("LOGIN"))

        try feed(channel, "A1 OK me@gmail.com authenticated (Success)\r\n")
        XCTAssertNoThrow(try future.wait())
        _ = try? channel.finish()
    }

    func testIMAPPasswordStillUsesLogin() throws {
        let (channel, future) = try makeIMAPVerifyChannel(authentication: .password("pw"))
        let sent = try feed(channel, "* OK Gimap ready\r\n")
        XCTAssertTrue(sent.hasPrefix("A1 LOGIN"), "got: \(sent)")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        XCTAssertNoThrow(try future.wait())
        _ = try? channel.finish()
    }

    func testIMAPAnswersXOAuth2ErrorChallengeAndReportsAuthFailure() throws {
        let (channel, future) = try makeIMAPVerifyChannel(authentication: .xoauth2(accessToken: "expired"))
        try feed(channel, "* OK Gimap ready\r\n")

        let challenge = Data(#"{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}"#.utf8)
            .base64EncodedString()
        let reply = try feed(channel, "+ \(challenge)\r\n")
        XCTAssertEqual(reply, "\r\n", "the client answers the error challenge with an empty response")

        try feed(channel, "A1 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n")
        XCTAssertThrowsError(try future.wait()) { error in
            guard case .authenticationFailed(let text) = error as? MailError else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
            XCTAssertTrue(text.contains("Invalid credentials"))
        }
        _ = try? channel.finish()
    }

    func testIMAPFetchHandlerAuthenticatesWithXOAuth2() throws {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: [MailMessage].self)
        let handler = IMAPFetchHandler(
            email: "me@gmail.com",
            authentication: .xoauth2(accessToken: "at"),
            mailboxName: "INBOX",
            limit: 5,
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([IMAPClientHandler(), handler])

        let sent = try feed(channel, "* OK Gimap ready\r\n")
        XCTAssertTrue(sent.hasPrefix("A1 AUTHENTICATE XOAUTH2 "), "got: \(sent)")
        let select = try feed(channel, "A1 OK authenticated\r\n")
        XCTAssertTrue(select.contains("SELECT"), "got: \(select)")
        try feed(channel, "* 0 EXISTS\r\n")
        try feed(channel, "A2 OK SELECT completed\r\n")
        XCTAssertEqual(try promise.futureResult.wait(), [])
        _ = try? channel.finish()
    }

    // MARK: - SMTP

    private func makeSMTPChannel(
        authentication: MailAuthentication
    ) throws -> (EmbeddedChannel, EventLoopFuture<Void>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let handler = SMTPSendHandler(
            email: "me@gmail.com",
            authentication: authentication,
            senderDomain: "gmail.com",
            envelope: SMTPEnvelope(sender: "me@gmail.com", recipients: ["alice@example.com"]),
            message: ByteBuffer(string: "Subject: Hi\r\n\r\nHello.\r\n"),
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([
            ByteToMessageHandler(SMTPResponseDecoder()),
            handler
        ])
        return (channel, promise.futureResult)
    }

    func testSMTPSendsAuthXOAuth2AndContinuesToMailFrom() throws {
        let (channel, future) = try makeSMTPChannel(authentication: .xoauth2(accessToken: "at"))
        try feed(channel, "220 smtp.gmail.com ESMTP\r\n")

        let auth = try feed(channel, "250-smtp.gmail.com\r\n250 AUTH LOGIN PLAIN XOAUTH2\r\n")
        let expected = XOAuth2.encodedInitialResponse(email: "me@gmail.com", accessToken: "at")
        XCTAssertEqual(auth, "AUTH XOAUTH2 \(expected)\r\n")

        let mailFrom = try feed(channel, "235 2.7.0 Accepted\r\n")
        XCTAssertTrue(mailFrom.contains("MAIL FROM:<me@gmail.com>"), "got: \(mailFrom)")
        try feed(channel, "250 OK\r\n")
        try feed(channel, "250 OK\r\n")
        try feed(channel, "354 Go ahead\r\n")
        try feed(channel, "250 OK queued\r\n")
        XCTAssertNoThrow(try future.wait())
        _ = try? channel.finish()
    }

    func testSMTPXOAuth2ErrorChallengeReportsAuthenticationFailure() throws {
        let (channel, future) = try makeSMTPChannel(authentication: .xoauth2(accessToken: "expired"))
        try feed(channel, "220 smtp.gmail.com ESMTP\r\n")
        try feed(channel, "250 AUTH XOAUTH2\r\n")

        let challenge = Data(#"{"status":"400","schemes":"Bearer"}"#.utf8).base64EncodedString()
        let reply = try feed(channel, "334 \(challenge)\r\n")
        XCTAssertEqual(reply, "\r\n", "the client answers the error challenge with an empty line")

        try feed(channel, "535 5.7.8 Username and Password not accepted\r\n")
        XCTAssertThrowsError(try future.wait()) { error in
            guard case .authenticationFailed(let text) = error as? MailError else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
            XCTAssertTrue(text.contains("535"))
            XCTAssertTrue(text.contains(#""status":"400""#), "challenge detail kept for diagnostics: \(text)")
        }
        _ = try? channel.finish()
    }

    func testSMTPXOAuth2TransientReplyAfterChallengeStaysRetryable() throws {
        let (channel, future) = try makeSMTPChannel(authentication: .xoauth2(accessToken: "at"))
        try feed(channel, "220 smtp.gmail.com ESMTP\r\n")
        try feed(channel, "250 AUTH XOAUTH2\r\n")

        let challenge = Data(#"{"status":"454","schemes":"Bearer"}"#.utf8).base64EncodedString()
        try feed(channel, "334 \(challenge)\r\n")
        try feed(channel, "454 4.7.0 Temporary authentication failure\r\n")
        XCTAssertThrowsError(try future.wait()) { error in
            guard case .smtpCommandFailed(let code, let message) = error as? MailError else {
                return XCTFail("expected smtpCommandFailed, got \(error)")
            }
            XCTAssertEqual(code, 454)
            XCTAssertTrue(message.contains("Temporary authentication failure"), "got: \(message)")
        }
        _ = try? channel.finish()
    }

    func testSMTPXOAuth2ServiceUnavailableAfterChallengeStaysRetryable() throws {
        let (channel, future) = try makeSMTPChannel(authentication: .xoauth2(accessToken: "at"))
        try feed(channel, "220 smtp.gmail.com ESMTP\r\n")
        try feed(channel, "250 AUTH XOAUTH2\r\n")
        try feed(channel, "334 \r\n")
        try feed(channel, "421 4.7.0 Try again later, closing connection\r\n")
        XCTAssertThrowsError(try future.wait()) { error in
            guard case .smtpCommandFailed(let code, _) = error as? MailError else {
                return XCTFail("expected smtpCommandFailed, got \(error)")
            }
            XCTAssertEqual(code, 421)
        }
        _ = try? channel.finish()
    }

    func testXOAuth2ChallengeDetailIgnoresNonBase64() {
        XCTAssertEqual(SMTPSendHandler.xoauth2ChallengeDetail("not base64!"), "")
    }
}
