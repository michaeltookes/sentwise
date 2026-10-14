import Foundation
import NIOCore
import NIOPosix
import NIOSSL

extension IMAPMailProvider {
    public func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }
        guard !rfc822.isEmpty else { throw MailError.commandFailed("The message to send is empty.") }
        guard !envelope.recipients.isEmpty else {
            throw MailError.commandFailed("The message has no recipients.")
        }

        let attempts = ChannelPromiseTracker<Void>()
        // Settle every tracked promise on exit — including losing Happy Eyeballs
        // candidates that never became active — so none is deallocated
        // unfulfilled (backlog item 77). The winner is already claimed by its
        // handler before this runs, so it is untouched.
        defer { attempts.failRemaining(MailError.connectionFailed("The connection attempt was superseded.")) }
        let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        let host = credentials.smtpHost
        let email = credentials.email
        let authentication = credentials.authentication

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    let complete = attempts.register(channel)
                    let handler = SMTPSendHandler(
                        email: email,
                        authentication: authentication,
                        senderDomain: SMTPSendHandler.domain(of: email),
                        envelope: envelope,
                        message: ByteBuffer(bytes: rfc822),
                        complete: complete
                    )
                    return channel.pipeline.addHandlers([
                        ssl,
                        ByteToMessageHandler(SMTPResponseDecoder()),
                        handler
                    ])
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: credentials.smtpPort).get()
        } catch {
            throw MailError.connectionFailed(String(describing: error))
        }
        guard let sendFuture = attempts.future(for: channel) else {
            try? await channel.close().get()
            throw MailError.connectionFailed("The mail connection could not start the send.")
        }

        let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)
        }
        defer { timeoutTask.cancel() }

        do {
            try await sendFuture.get()
            try? await channel.close().get()
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

/// A single SMTP reply: the 3-digit status code plus the joined text of all its
/// (possibly multi-line) response lines.
struct SMTPResponse: Equatable {
    let code: Int
    let text: String
}

/// Frames the SMTP reply stream into `SMTPResponse` values. SMTP replies are
/// CRLF-terminated lines beginning with a 3-digit code; a hyphen after the code
/// (`250-`) marks a continuation, a space (`250 `) the final line of the reply.
final class SMTPResponseDecoder: ByteToMessageDecoder {
    typealias InboundOut = SMTPResponse

    private var pendingCode: Int?

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let newlineIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            return .needMoreData
        }
        let lineLength = newlineIndex - buffer.readerIndex + 1
        guard var line = buffer.readString(length: lineLength) else { return .needMoreData }
        line = String(line.reversed().drop(while: { $0 == "\n" || $0 == "\r" }).reversed())

        guard line.count >= 3, let code = Int(line.prefix(3)) else {
            throw MailError.commandFailed("Malformed SMTP reply: \(line)")
        }
        // A space (or bare 3-char line) ends the reply; a hyphen continues it.
        let isFinal = line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] != "-"
        pendingCode = code

        if isFinal {
            let text = line.count > 4
                ? String(line.dropFirst(4))
                : ""
            context.fireChannelRead(wrapInboundOut(SMTPResponse(code: code, text: text)))
            pendingCode = nil
        }
        return .continue
    }

    func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

/// Drives the SMTP submission exchange over an already-TLS'd channel:
/// greeting → EHLO → AUTH LOGIN (app password) or AUTH XOAUTH2 (OAuth access
/// token, item 104) → MAIL FROM → RCPT TO… → DATA → body → QUIT,
/// settling via `complete` when the server accepts the message (250 after DATA).
final class SMTPSendHandler: ChannelInboundHandler {
    typealias InboundIn = SMTPResponse
    typealias OutboundOut = ByteBuffer

    private enum Step {
        case greeting, ehlo, authUsername, authPassword, authComplete
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
        complete: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
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
        case .greeting:
            guard expect(response, 220, context: context) else { return }
            send("EHLO \(senderDomain)", context: context)
            step = .ehlo
        case .ehlo:
            guard expect(response, 250, context: context) else { return }
            sendAuth(context: context)
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
            send("MAIL FROM:<\(envelope.sender)>", context: context)
            step = .mailFrom
        case .authXOAuth2Rejected(let detail):
            let reply = replyText(response)
            let message = detail.isEmpty ? reply : "\(reply) (\(detail))"
            // Only a permanent (5xx) reply is a credential failure. A transient
            // one (421, 454, any 4xx) stays a retryable command failure, the same
            // split `expect(_:_:context:auth:)` makes for the other AUTH steps.
            if isPermanentAuthFailure(response.code) {
                settle(.failure(MailError.authenticationFailed(message)))
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

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        settle(.failure(connectionFailure(String(describing: error))))
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

    // MARK: - Sending

    private var appPassword: String {
        if case .password(let password) = authentication { return password }
        return ""
    }

    private func sendAuth(context: ChannelHandlerContext) {
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
                settle(.failure(MailError.authenticationFailed(replyText(response))))
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
