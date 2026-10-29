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

        try await runSMTP(credentials, rfc822: rfc822, envelope: envelope, authenticateOnly: false)
    }

    /// Connect-time probe (item 31, T31-7): connect, upgrade (STARTTLS) when the
    /// account asks for it, authenticate (XOAUTH2 or login), QUIT. No mail is sent.
    /// SMTP AUTH being disabled for the mailbox surfaces as `.mailboxProtocolDisabled`.
    public func probeSMTPAuthentication(_ credentials: MailAccountCredentials) async throws {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }
        try await runSMTP(
            credentials,
            rfc822: Data(),
            envelope: SMTPEnvelope(sender: credentials.email, recipients: []),
            authenticateOnly: true
        )
    }

    private func runSMTP(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope,
        authenticateOnly: Bool
    ) async throws {
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
        let security = credentials.smtpSecurity

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    let complete = attempts.register(channel)
                    let decoder = SMTPResponseDecoder()
                    let handler = SMTPSendHandler(
                        email: email,
                        authentication: authentication,
                        senderDomain: SMTPSendHandler.domain(of: email),
                        envelope: envelope,
                        message: ByteBuffer(bytes: rfc822),
                        security: security,
                        makeTLSHandler: {
                            try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                        },
                        decoder: decoder,
                        authenticateOnly: authenticateOnly,
                        complete: complete
                    )
                    var handlers: [ChannelHandler] = []
                    if security == .implicitTLS {
                        handlers.append(try NIOSSLClientHandler(context: sslContext, serverHostname: host))
                    }
                    handlers.append(ByteToMessageHandler(decoder))
                    handlers.append(handler)
                    return channel.pipeline.addHandlers(handlers)
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
