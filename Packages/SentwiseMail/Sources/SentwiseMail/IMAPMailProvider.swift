import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

/// A `MailProvider` backed by SwiftNIO's IMAP stack (`NIOIMAP` over `NIOSSL`).
///
/// `verifyConnection` opens a TLS connection, authenticates (IMAP `LOGIN` with
/// the app password, or `AUTHENTICATE XOAUTH2` with an OAuth token), and logs out — the basis of the Settings "Test Connection"
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
        _ = try await verify(credentials, discover: false)
    }

    public func verifyAndDiscover(_ credentials: MailAccountCredentials) async throws -> MailboxNaming? {
        try await verify(credentials, discover: true)
    }

    private func verify(_ credentials: MailAccountCredentials, discover: Bool) async throws -> MailboxNaming? {
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
        let authentication = credentials.authentication
        let discovery = DiscoveryBox()

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    let complete = attempts.register(channel)
                    let verify = IMAPVerifyHandler(
                        email: email, authentication: authentication,
                        discovery: discover ? discovery : nil, complete: complete
                    )
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
        guard discover, let entries = discovery.entries else { return nil }
        return MailboxNaming.forHost(credentials.host).discovering(from: entries)
    }
}

/// Carries the raw `LIST` entries from the channel's event loop back to the
/// caller. Written once before the verification future completes and read only
/// after it, so the future provides the ordering.
final class DiscoveryBox: @unchecked Sendable {
    var entries: [MailboxListEntry]?
}

public enum LiveMailProvider {
    public static func imap() -> any MailProvider {
        imapProvider()
    }

    public static func imapProvider() -> IMAPMailProvider {
        IMAPMailProvider()
    }
}

/// Drives a minimal IMAP authenticate/`LOGOUT` exchange and settles via `complete`.
///
/// The exchange: wait for the server greeting (an untagged response), send a
/// tagged `LOGIN`, and complete on the tagged result.
final class IMAPVerifyHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    private let email: String
    private let authentication: MailAuthentication
    private let complete: @Sendable (Result<Void, Error>) -> Void
    private let loginTag = "A1"
    private let logoutTag = "A2"
    private let listTag = "A3"
    private let discovery: DiscoveryBox?
    private var collected: [MailboxListEntry] = []
    private var didSendLogin = false
    private var loggedIn = false
    private var settled = false

    /// `discovery` non-nil asks for one `LIST "" "*"` after login (item 31,
    /// T31-8); verification then settles only once the LIST finishes, but a
    /// failed LIST still settles as success.
    init(
        email: String,
        authentication: MailAuthentication,
        discovery: DiscoveryBox? = nil,
        complete: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.email = email
        self.authentication = authentication
        self.discovery = discovery
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
                loggedIn = true
                if discovery != nil {
                    sendList(context: context)
                } else {
                    settle(.success(()))
                    sendLogout(context: context)
                }
            case .no(let text), .bad(let text):
                settle(.failure(MailError.authenticationFailed(text.text)))
                context.close(promise: nil)
            }
        case .tagged(let tagged) where tagged.tag == listTag:
            if case .ok = tagged.state { discovery?.entries = collected }
            settle(.success(()))
            sendLogout(context: context)
        case .untagged(.mailboxData(.list(let info))) where loggedIn:
            // Raw wire names (not display-decoded) so SELECT/APPEND reuse them.
            let name = String(bytes: info.path.name.bytes, encoding: .utf8) ?? ""
            collected.append(MailboxListEntry(attributes: info.attributes.map { String($0) }, name: name))
        case .authenticationChallenge:
            if case .xoauth2 = authentication {
                IMAPAuthentication.answerChallenge(context: context)
            }
        case .fatal(let text):
            settle(loggedIn ? .success(()) : .failure(MailError.connectionFailed(text.text)))
            context.close(promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        settle(loggedIn ? .success(()) : .failure(MailError.connectionFailed(String(describing: error))))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // After a successful login a dropped connection only costs discovery.
        settle(loggedIn
            ? .success(())
            : .failure(MailError.connectionFailed("The connection closed before authentication completed.")))
        context.fireChannelInactive()
    }

    private func sendLogin(context: ChannelHandlerContext) {
        didSendLogin = true
        let command = TaggedCommand(tag: loginTag, command: IMAPAuthentication.command(email: email, authentication: authentication))
        context.writeAndFlush(NIOAny(IMAPClientHandler.Message.part(.tagged(command))), promise: nil)
    }

    private func sendList(context: ChannelHandlerContext) {
        let command = TaggedCommand(tag: listTag, command: .list(
            nil, reference: MailboxName(ByteBuffer(string: "")), .mailbox(ByteBuffer(string: "*"))
        ))
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
