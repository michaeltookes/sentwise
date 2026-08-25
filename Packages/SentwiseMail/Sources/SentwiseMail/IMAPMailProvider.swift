import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

/// A `MailProvider` backed by SwiftNIO's IMAP stack (`NIOIMAP` over `NIOSSL`).
///
/// `verifyConnection` opens a TLS connection, performs an IMAP `LOGIN` with the
/// app password, and logs out — the basis of the Settings "Test Connection"
/// action. Message fetch/send are added in later slices.
public struct IMAPMailProvider: MailProvider {

    let group: EventLoopGroup
    let timeout: TimeAmount

    public init(
        group: EventLoopGroup = NIOSingletons.posixEventLoopGroup,
        timeout: TimeAmount = .seconds(20)
    ) {
        self.group = group
        self.timeout = timeout
    }

    public func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }

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

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    let complete = attempts.register(channel)
                    let verify = IMAPVerifyHandler(email: email, password: password, complete: complete)
                    return channel.pipeline.addHandlers([ssl, IMAPClientHandler(), verify])
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
        guard let verification = attempts.future(for: channel) else {
            try? await channel.close().get()
            throw MailError.connectionFailed("The mail connection could not start verification.")
        }

        // Fail-safe: close the channel if nothing settles within the timeout;
        // channelInactive then completes the promise (guarded against races).
        let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)
        }
        defer { timeoutTask.cancel() }

        do {
            try await verification.get()
        } catch {
            try? await channel.close().get()
            throw error
        }
        try? await channel.close().get()
    }
}

/// Drives a minimal IMAP `LOGIN`/`LOGOUT` exchange and settles via `complete`.
///
/// The exchange: wait for the server greeting (an untagged response), send a
/// tagged `LOGIN`, and complete on the tagged result.
final class IMAPVerifyHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    private let email: String
    private let password: String
    private let complete: @Sendable (Result<Void, Error>) -> Void
    private let loginTag = "A1"
    private let logoutTag = "A2"
    private var didSendLogin = false
    private var settled = false

    init(email: String, password: String, complete: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.email = email
        self.password = password
        self.complete = complete
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        switch response {
        case .untagged:
            // First untagged response is the greeting → authenticate.
            if !didSendLogin {
                sendLogin(context: context)
            }
        case .tagged(let tagged) where tagged.tag == loginTag:
            switch tagged.state {
            case .ok:
                settle(.success(()))
                sendLogout(context: context)
            case .no(let text), .bad(let text):
                settle(.failure(MailError.authenticationFailed(text.text)))
                context.close(promise: nil)
            }
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
        settle(.failure(MailError.connectionFailed("The connection closed before authentication completed.")))
        context.fireChannelInactive()
    }

    private func sendLogin(context: ChannelHandlerContext) {
        didSendLogin = true
        let command = TaggedCommand(tag: loginTag, command: .login(username: email, password: password))
        context.writeAndFlush(NIOAny(IMAPClientHandler.Message.part(.tagged(command))), promise: nil)
    }

    private func sendLogout(context: ChannelHandlerContext) {
        let command = TaggedCommand(tag: logoutTag, command: .logout)
        context.writeAndFlush(NIOAny(IMAPClientHandler.Message.part(.tagged(command))), promise: nil)
        context.close(promise: nil)
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        complete(result)
    }
}
