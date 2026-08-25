import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

extension IMAPMailProvider {
    public func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil
    ) async throws -> Data {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }
        guard uid > 0 else { throw MailError.commandFailed("A message UID is required to fetch a body.") }

        let attempts = ChannelPromiseTracker<Data>()
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
                    let handler = IMAPBodyFetchHandler(
                        email: email,
                        password: password,
                        mailboxName: mailboxName,
                        uid: uid,
                        expectedUIDValidity: expectedUIDValidity,
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
        guard let bodyFuture = attempts.future(for: channel) else {
            try? await channel.close().get()
            throw MailError.connectionFailed("The mail connection could not start fetching.")
        }

        let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)
        }
        defer { timeoutTask.cancel() }

        do {
            let body = try await bodyFuture.get()
            try? await channel.close().get()
            return body
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

/// Drives LOGIN → SELECT → UID FETCH (BODY.PEEK[TEXT]) → LOGOUT and settles via
/// `complete` with the assembled raw text body.
final class IMAPBodyFetchHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    private enum Step {
        case greeting, login, select, fetch, done
    }

    private let email: String
    private let password: String
    private let mailboxName: String
    private let uid: UInt32
    private let expectedUIDValidity: UInt32?
    private let complete: @Sendable (Result<Data, Error>) -> Void

    private let loginTag = "A1"
    private let selectTag = "A2"
    private let fetchTag = "A3"
    private let logoutTag = "A4"

    private var step: Step = .greeting
    private var settled = false
    private var body = ByteBuffer()
    private var receivedBody = false
    private var didReceiveBodySection = false
    private var selectedUIDValidity: UInt32?

    init(
        email: String,
        password: String,
        mailboxName: String,
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil,
        complete: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        self.email = email
        self.password = password
        self.mailboxName = mailboxName
        self.uid = uid
        self.expectedUIDValidity = expectedUIDValidity
        self.complete = complete
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .untagged(let payload):
            handleUntagged(payload, context: context)
        case .fetch(let fetchResponse):
            handleFetch(fetchResponse)
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
        settle(.failure(MailError.connectionFailed("The connection closed before the fetch completed.")))
        context.fireChannelInactive()
    }

    // MARK: - Response handling

    private func handleUntagged(_ payload: ResponsePayload, context: ChannelHandlerContext) {
        captureUIDValidity(from: payload)

        // Only the greeting matters here; SELECT's untagged data (EXISTS etc.)
        // is irrelevant because we address the message by UID.
        if step == .greeting {
            send(.login(username: email, password: password), tag: loginTag, context: context)
            step = .login
        }
    }

    private func handleTagged(_ tagged: TaggedResponse, context: ChannelHandlerContext) {
        switch tagged.tag {
        case loginTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            send(.select(MailboxName(ByteBuffer(string: mailboxName))), tag: selectTag, context: context)
            step = .select
        case selectTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            captureUIDValidity(from: tagged.state)
            guard verifySelectedUIDValidity() else {
                step = .done
                send(.logout, tag: logoutTag, context: context)
                context.close(promise: nil)
                return
            }
            let range = MessageIdentifierRange<UID>(UID(rawValue: uid))
            let set = MessageIdentifierSetNonEmpty(range: range)
            send(.uidFetch(.set(set), [.bodySection(peek: true, .text, nil)], []), tag: fetchTag, context: context)
            step = .fetch
        case fetchTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            guard didReceiveBodySection else {
                settle(.failure(MailError.commandFailed("No body was returned for the selected message.")))
                step = .done
                send(.logout, tag: logoutTag, context: context)
                context.close(promise: nil)
                return
            }
            settle(.success(bodyData()))
            step = .done
            send(.logout, tag: logoutTag, context: context)
            context.close(promise: nil)
        default:
            break
        }
    }

    private func handleFetch(_ response: FetchResponse) {
        switch response {
        case .streamingBegin(let kind, _):
            // Only accumulate the BODY[TEXT] stream — ignore any other section.
            if case .body = kind {
                receivedBody = true
                didReceiveBodySection = true
            }
        case .streamingBytes(var chunk):
            if receivedBody { body.writeBuffer(&chunk) }
        case .streamingEnd:
            receivedBody = false
        default:
            break
        }
    }

    // MARK: - Commands

    private func send(_ command: Command, tag: String, context: ChannelHandlerContext) {
        let part = CommandStreamPart.tagged(TaggedCommand(tag: tag, command: command))
        context.writeAndFlush(NIOAny(IMAPClientHandler.Message.part(part)), promise: nil)
    }

    // MARK: - Helpers

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

    private func captureUIDValidity(from payload: ResponsePayload) {
        guard case .conditionalState(.ok(let text)) = payload,
              case .some(.uidValidity(let value)) = text.code else {
            return
        }
        selectedUIDValidity = UInt32(value)
    }

    private func captureUIDValidity(from state: TaggedResponse.State) {
        guard case .ok(let text) = state,
              case .some(.uidValidity(let value)) = text.code else {
            return
        }
        selectedUIDValidity = UInt32(value)
    }

    private func verifySelectedUIDValidity() -> Bool {
        guard let expectedUIDValidity else { return true }
        guard let selectedUIDValidity else {
            settle(.failure(MailError.commandFailed("The mailbox UIDVALIDITY could not be verified.")))
            return false
        }
        guard selectedUIDValidity == expectedUIDValidity else {
            settle(.failure(MailError.commandFailed("The mailbox changed before the message body was fetched.")))
            return false
        }
        return true
    }

    private func bodyData() -> Data {
        var buffer = body
        return Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }

    private func settle(_ result: Result<Data, Error>) {
        guard !settled else { return }
        settled = true
        complete(result)
    }
}
