import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// Drives the SMTP submission exchange. With implicit TLS the channel is already
/// encrypted; with `SMTPSecurity.startTLS` the handler first runs greeting → EHLO
/// → STARTTLS → (TLS handler inserted at the head of the pipeline) → EHLO again,
/// and refuses to authenticate unless that upgrade completed (item 31, T31-6).
/// The authenticated exchange is: greeting → EHLO → AUTH LOGIN (app password) or AUTH XOAUTH2 (OAuth access
/// token, item 104) → MAIL FROM → RCPT TO… → DATA → body → QUIT,
/// settling via `complete` when the server accepts the message (250 after DATA).
final class SMTPSendHandler: ChannelInboundHandler {
    typealias InboundIn = SMTPResponse
    typealias OutboundOut = ByteBuffer

    private enum Step {
        case greeting, ehlo, startTLS, awaitingTLS, authUsername, authPassword, authComplete
        /// `AUTH XOAUTH2` was rejected with a `334` error challenge; the empty
        /// reply was sent and the final `5xx` is pending.
        case authXOAuth2Rejected(String)
        case mailFrom, rcpt(Int), dataCommand, dataBody, quit, done
    }

    private let email: String
    private let authentication: MailAuthentication
    private let senderDomain: String
    private let envelope: SMTPEnvelope
    private let message: ByteBuffer
    private let complete: @Sendable (Result<Void, Error>) -> Void
    private let security: SMTPSecurity
    /// Builds the TLS handler inserted after a successful `STARTTLS` reply.
    private let makeTLSHandler: (() throws -> ChannelHandler)?
    private let decoder: SMTPResponseDecoder?
    /// When true the exchange stops after a `235` (AUTH accepted): QUIT, no
    /// MAIL FROM, no message. Used by the connect-time probe (item 31, T31-7).
    private let authenticateOnly: Bool

    /// True once the transport is encrypted: always for implicit TLS, after the
    /// upgrade for STARTTLS. AUTH is never sent while this is false.
    private var isEncrypted: Bool
    /// True between inserting the TLS handler and the first reply over it, so a
    /// handshake failure surfaces as `starttlsFailed` rather than a generic drop.
    private var tlsHandshakePending = false

    private var step: Step = .greeting
    private var settled = false
    /// Set the instant the message body is written to the wire. Once true, any
    /// connection-level failure (drop/timeout/I-O error) before the final 250 is
    /// *ambiguous* — the server may have accepted the message — so it surfaces as
    /// `sendInterruptedAfterSubmission` and must not be auto-retried (item 27).
    private var didSubmitData = false

    init(
        email: String,
        authentication: MailAuthentication,
        senderDomain: String,
        envelope: SMTPEnvelope,
        message: ByteBuffer,
        security: SMTPSecurity = .implicitTLS,
        makeTLSHandler: (() throws -> ChannelHandler)? = nil,
        decoder: SMTPResponseDecoder? = nil,
        authenticateOnly: Bool = false,
        complete: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.authenticateOnly = authenticateOnly
        self.security = security
        self.makeTLSHandler = makeTLSHandler
        self.decoder = decoder
        self.isEncrypted = security == .implicitTLS
        self.email = email
        self.authentication = authentication
        self.senderDomain = senderDomain
        self.envelope = envelope
        self.message = message
        self.complete = complete
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        switch step {
        case .awaitingTLS:
            // Nothing may arrive before the handshake completes; a reply here is
            // forged or out of order, never a real answer.
            settle(.failure(MailError.starttlsFailed("Unexpected data before the TLS handshake completed.")))
            context.close(promise: nil)
        case .greeting:
            guard expect(response, 220, context: context) else { return }
            send("EHLO \(senderDomain)", context: context)
            step = .ehlo
        case .ehlo:
            guard expect(response, 250, context: context) else { return }
            if !isEncrypted {
                // STARTTLS mode, plaintext phase: the server must offer the upgrade.
                guard response.advertises("STARTTLS") else {
                    settle(.failure(MailError.starttlsNotOffered))
                    context.close(promise: nil)
                    return
                }
                decoder?.rejectTrailingData = true
                send("STARTTLS", context: context)
                step = .startTLS
                return
            }
            sendAuth(context: context)
        case .startTLS:
            guard response.code == 220 else {
                settle(.failure(MailError.starttlsFailed(replyText(response))))
                context.close(promise: nil)
                return
            }
            upgradeToTLS(context: context)
        case .authUsername:
            guard expect(response, 334, context: context, auth: true) else { return }
            send(Data(email.utf8).base64EncodedString(), context: context)
            step = .authPassword
        case .authPassword:
            guard expect(response, 334, context: context, auth: true) else { return }
            send(Data(appPassword.utf8).base64EncodedString(), context: context)
            step = .authComplete
        case .authComplete:
            if response.code == 334, case .xoauth2 = authentication {
                // Gmail's XOAUTH2 error challenge: answer with an empty line to
                // receive the final failure reply.
                step = .authXOAuth2Rejected(Self.xoauth2ChallengeDetail(response.text))
                send("", context: context)
                return
            }
            guard expect(response, 235, context: context, auth: true) else { return }
            if authenticateOnly {
                settle(.success(()))
                step = .quit
                send("QUIT", context: context)
                context.close(promise: nil)
                return
            }
            send("MAIL FROM:<\(envelope.sender)>", context: context)
            step = .mailFrom
        case .authXOAuth2Rejected(let detail):
            let reply = replyText(response)
            let message = detail.isEmpty ? reply : "\(reply) (\(detail))"
            // Only a permanent (5xx) reply is a credential failure. A transient
            // one (421, 454, any 4xx) stays a retryable command failure, the same
            // split `expect(_:_:context:auth:)` makes for the other AUTH steps.
            if isPermanentAuthFailure(response.code) {
                settle(.failure(authFailure(message)))
            } else {
                settle(.failure(MailError.smtpCommandFailed(code: response.code, message: message)))
            }
            context.close(promise: nil)
        case .mailFrom:
            guard expect(response, 250, context: context) else { return }
            sendRecipient(0, context: context)
        case .rcpt(let index):
            // 250 (OK) and 251 (will forward) both accept the recipient.
            guard response.code == 250 || response.code == 251 else {
                return failCommand(response, context: context)
            }
            let next = index + 1
            if next < envelope.recipients.count {
                sendRecipient(next, context: context)
            } else {
                send("DATA", context: context)
                step = .dataCommand
            }
        case .dataCommand:
            guard expect(response, 354, context: context) else { return }
            sendBody(context: context)
            step = .dataBody
        case .dataBody:
            guard expect(response, 250, context: context) else { return }
            settle(.success(()))
            step = .quit
            send("QUIT", context: context)
            context.close(promise: nil)
        case .quit, .done:
            break
        }
    }

    /// The handshake-completed event is the only thing that releases the
    /// post-upgrade EHLO and marks the channel encrypted.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .awaitingTLS = step, event is TLSUserEvent {
            tlsHandshakePending = false
            isEncrypted = true
            send("EHLO \(senderDomain)", context: context)
            step = .ehlo
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let mailError = error as? MailError, case .starttlsFailed = mailError {
            settle(.failure(mailError))
        } else if tlsHandshakePending {
            settle(.failure(MailError.starttlsFailed(String(describing: error))))
        } else {
            settle(.failure(connectionFailure(String(describing: error))))
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle(.failure(connectionFailure("The connection closed before the message was sent.")))
        context.fireChannelInactive()
    }

    /// Classifies a connection-level failure by phase: ambiguous once the DATA
    /// body has been submitted (never auto-retry), plainly transient before then.
    private func connectionFailure(_ detail: String) -> MailError {
        didSubmitData
            ? .sendInterruptedAfterSubmission(detail)
            : .connectionFailed(detail)
    }
}

extension SMTPSendHandler {
    // MARK: - Sending

    private var appPassword: String {
        if case .password(let password) = authentication { return password }
        return ""
    }

    /// Inserts the TLS handler ahead of the decoder and, once it is in place,
    /// re-issues EHLO over the encrypted channel (RFC 3207 requires a fresh EHLO).
    private func upgradeToTLS(context: ChannelHandlerContext) {
        guard let makeTLSHandler else {
            settle(.failure(MailError.starttlsFailed("No TLS handler is available.")))
            context.close(promise: nil)
            return
        }
        do {
            try context.pipeline.syncOperations.addHandler(try makeTLSHandler(), position: .first)
        } catch {
            settle(.failure(MailError.starttlsFailed(String(describing: error))))
            context.close(promise: nil)
            return
        }
        decoder?.rejectTrailingData = false
        tlsHandshakePending = true
        step = .awaitingTLS
    }

    private func sendAuth(context: ChannelHandlerContext) {
        // Never authenticate over an unencrypted channel (no plaintext fallback).
        guard isEncrypted else {
            settle(.failure(MailError.starttlsNotOffered))
            context.close(promise: nil)
            return
        }
        switch authentication {
        case .password:
            send("AUTH LOGIN", context: context)
            step = .authUsername
        case .xoauth2(let accessToken):
            let initial = XOAuth2.encodedInitialResponse(email: email, accessToken: accessToken)
            send("AUTH \(XOAuth2.mechanism) \(initial)", context: context)
            step = .authComplete
        }
    }

    private func sendRecipient(_ index: Int, context: ChannelHandlerContext) {
        send("RCPT TO:<\(envelope.recipients[index])>", context: context)
        step = .rcpt(index)
    }

    private func sendBody(context: ChannelHandlerContext) {
        // From this write until the final 250, a connection drop is ambiguous.
        didSubmitData = true
        var payload = Self.dotStuffed(message)
        // Terminate DATA with <CRLF>.<CRLF>; add the leading CRLF only if the
        // message doesn't already end with one.
        if !Self.endsWithCRLF(payload) {
            payload.writeString("\r\n")
        }
        payload.writeString(".\r\n")
        context.writeAndFlush(wrapOutboundOut(payload), promise: nil)
    }

    private func send(_ line: String, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: line.utf8.count + 2)
        buffer.writeString(line)
        buffer.writeString("\r\n")
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    // MARK: - Helpers

    /// Validates the reply code for the current step, failing the send on a
    /// mismatch. Permanent auth failures route to `authenticationFailed`, while
    /// temporary auth replies keep their SMTP code so callers can retry them.
    private func expect(
        _ response: SMTPResponse,
        _ code: Int,
        context: ChannelHandlerContext,
        auth: Bool = false
    ) -> Bool {
        guard response.code == code else {
            if auth, isPermanentAuthFailure(response.code) {
                settle(.failure(authFailure(replyText(response))))
                context.close(promise: nil)
            } else {
                failCommand(response, context: context)
            }
            return false
        }
        return true
    }

    private func failCommand(_ response: SMTPResponse, context: ChannelHandlerContext) {
        settle(.failure(MailError.smtpCommandFailed(code: response.code, message: replyText(response))))
        context.close(promise: nil)
    }

    private func authFailure(_ message: String) -> MailError {
        SMTPAuthDisabledDetector.isDisabled(message)
            ? .mailboxProtocolDisabled(.smtp, message)
            : .authenticationFailed(message)
    }

    private func replyText(_ response: SMTPResponse) -> String {
        response.text.isEmpty ? "SMTP error \(response.code)" : "\(response.code) \(response.text)"
    }

    private func isPermanentAuthFailure(_ code: Int) -> Bool {
        code >= 500
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        complete(result)
    }

    /// Decodes Gmail's base64 JSON XOAUTH2 error challenge (e.g.
    /// `{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}`)
    /// into readable text for diagnostics; returns "" when it is not decodable.
    static func xoauth2ChallengeDetail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              let decoded = String(data: data, encoding: .utf8) else { return "" }
        return decoded
    }

    static func domain(of email: String) -> String {
        email.split(separator: "@").last.map(String.init) ?? "localhost"
    }

    /// Dot-stuffs a message for SMTP DATA: any line beginning with `.` gets an
    /// extra leading `.` so it isn't read as the end-of-data terminator.
    static func dotStuffed(_ message: ByteBuffer) -> ByteBuffer {
        let bytes = message.readableBytesView
        var out = ByteBufferAllocator().buffer(capacity: bytes.count + 16)
        var atLineStart = true
        for byte in bytes {
            if atLineStart && byte == UInt8(ascii: ".") {
                out.writeInteger(UInt8(ascii: "."))
            }
            out.writeInteger(byte)
            atLineStart = (byte == UInt8(ascii: "\n"))
        }
        return out
    }

    private static func endsWithCRLF(_ buffer: ByteBuffer) -> Bool {
        let bytes = buffer.readableBytesView
        guard bytes.count >= 2 else { return false }
        return bytes[bytes.index(bytes.endIndex, offsetBy: -2)] == UInt8(ascii: "\r")
            && bytes[bytes.index(bytes.endIndex, offsetBy: -1)] == UInt8(ascii: "\n")
    }
}
