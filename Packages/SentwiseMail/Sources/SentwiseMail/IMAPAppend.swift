import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

extension IMAPMailProvider {
    public func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }
        guard !rfc822.isEmpty else { throw MailError.commandFailed("The message to append is empty.") }

        let attempts = ChannelPromiseTracker<Void>()
        // Settle every tracked promise on exit — including losing Happy Eyeballs
        // candidates that never became active — so none is deallocated
        // unfulfilled (backlog item 77). The winner is already claimed by its
        // handler before this runs, so it is untouched.
        defer { attempts.failRemaining(MailError.connectionFailed("The connection attempt was superseded.")) }
        let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        let host = credentials.host
        let email = credentials.email
        let password = credentials.appPassword
        let mailboxName = mailbox.imapName(using: credentials.mailboxNaming)

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    let complete = attempts.register(channel)
                    let handler = IMAPAppendHandler(
                        email: email,
                        password: password,
                        mailboxName: mailboxName,
                        message: ByteBuffer(bytes: rfc822),
                        flags: flags,
                        complete: complete
                    )
                    return channel.pipeline.addHandlers([ssl, IMAPClientHandler(), handler])
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: credentials.host, port: credentials.port).get()
        } catch {
            throw MailError.connectionFailed(String(describing: error))
        }
        guard let appendFuture = attempts.future(for: channel) else {
            try? await channel.close().get()
            throw MailError.connectionFailed("The mail connection could not start the append.")
        }

        let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)
        }
        defer { timeoutTask.cancel() }

        do {
            try await appendFuture.get()
            try? await channel.close().get()
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

/// Drives LOGIN → APPEND (message literal with flags) → LOGOUT and settles via
/// `complete` when the append is acknowledged. The `IMAPClientHandler` buffers
/// the message bytes and releases them on the server's continuation request.
final class IMAPAppendHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    private enum Step {
        case greeting, login, append, done
    }

    private let email: String
    private let password: String
    private let mailboxName: String
    private let message: ByteBuffer
    private let flags: [MailFlag]
    private let complete: @Sendable (Result<Void, Error>) -> Void

    private let loginTag = "A1"
    private let appendTag = "A2"
    private let logoutTag = "A3"

    private var step: Step = .greeting
    private var settled = false

    init(
        email: String,
        password: String,
        mailboxName: String,
        message: ByteBuffer,
        flags: [MailFlag],
        complete: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.email = email
        self.password = password
        self.mailboxName = mailboxName
        self.message = message
        self.flags = flags
        self.complete = complete
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .untagged:
            if step == .greeting {
                sendTagged(.login(username: email, password: password), tag: loginTag, context: context)
                step = .login
            }
        case .tagged(let tagged):
            handleTagged(tagged, context: context)
        case .fatal(let text):
            settle(.failure(MailError.connectionFailed(text.text)))
            context.close(promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        settle(.failure(MailError.connectionFailed(String(describing: error))))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle(.failure(MailError.connectionFailed("The connection closed before the append completed.")))
        context.fireChannelInactive()
    }

    private func handleTagged(_ tagged: TaggedResponse, context: ChannelHandlerContext) {
        switch tagged.tag {
        case loginTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            sendAppend(context: context)
            step = .append
        case appendTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            settle(.success(()))
            step = .done
            sendTagged(.logout, tag: logoutTag, context: context)
            context.close(promise: nil)
        default:
            break
        }
    }

    private func sendAppend(context: ChannelHandlerContext) {
        let mailbox = MailboxName(ByteBuffer(string: mailboxName))
        let options = AppendOptions(flagList: flags.map(Self.imapFlag))
        let appendMessage = AppendMessage(options: options, data: AppendData(byteCount: message.readableBytes))
        write(.append(.start(tag: appendTag, appendingTo: mailbox)), context: context)
        write(.append(.beginMessage(message: appendMessage)), context: context)
        write(.append(.messageBytes(message)), context: context)
        write(.append(.endMessage), context: context)
        write(.append(.finish), context: context)
    }

    // MARK: - Helpers

    private func sendTagged(_ command: Command, tag: String, context: ChannelHandlerContext) {
        write(.tagged(TaggedCommand(tag: tag, command: command)), context: context)
    }

    private func write(_ part: CommandStreamPart, context: ChannelHandlerContext) {
        context.writeAndFlush(NIOAny(IMAPClientHandler.Message.part(part)), promise: nil)
    }

    private static func imapFlag(_ flag: MailFlag) -> Flag {
        switch flag {
        case .draft: return .draft
        case .seen: return .seen
        }
    }

    private func isOK(_ state: TaggedResponse.State) -> Bool {
        if case .ok = state { return true }
        return false
    }

    private func failTagged(_ state: TaggedResponse.State) {
        switch state {
        case .no(let text), .bad(let text):
            let error: MailError = step == .login
                ? .authenticationFailed(text.text)
                : .commandFailed(text.text)
            settle(.failure(error))
        case .ok:
            break
        }
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        complete(result)
    }
}
