import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

extension IMAPMailProvider {
    public func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }
        guard limit > 0 else { return [] }

        let attempts = ChannelPromiseTracker<[MailMessage]>()
        // Always settle every tracked promise, including losing Happy Eyeballs
        // candidates that never became active, so none is deallocated unfulfilled
        // (backlog item 77). The winner is already claimed by its handler by the
        // time this runs, so it is untouched.
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
                    let handler = IMAPFetchHandler(
                        email: email,
                        password: password,
                        mailboxName: mailboxName,
                        limit: limit,
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
        guard let fetchFuture = attempts.future(for: channel) else {
            try? await channel.close().get()
            throw MailError.connectionFailed("The mail connection could not start fetching.")
        }

        let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)
        }
        defer { timeoutTask.cancel() }

        do {
            let messages = try await fetchFuture.get()
            try? await channel.close().get()
            return messages
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

/// Drives LOGIN → SELECT → FETCH (envelope) → LOGOUT and settles via `complete`
/// with the parsed messages, newest first.
final class IMAPFetchHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    private enum Step {
        case greeting, login, select, fetch, done
    }

    private struct PartialMessage {
        var uid: UInt32?
        var from: MailAddress?
        var replyTo: MailAddress?
        var to: [MailAddress] = []
        var hasEnvelope = false
        var subject = ""
        var date = ""
        var inReplyTo: String?
        var messageID: String?
    }

    private let email: String
    private let password: String
    private let mailboxName: String
    private let limit: Int
    private let complete: @Sendable (Result<[MailMessage], Error>) -> Void

    private let loginTag = "A1"
    private let selectTag = "A2"
    private let fetchTag = "A3"
    private let logoutTag = "A4"

    private var step: Step = .greeting
    private var settled = false
    private var messageCount = 0
    private var selectedUIDValidity: UInt32?
    private var messages: [MailMessage] = []
    private var current: PartialMessage?

    init(
        email: String,
        password: String,
        mailboxName: String,
        limit: Int,
        complete: @escaping @Sendable (Result<[MailMessage], Error>) -> Void
    ) {
        self.email = email
        self.password = password
        self.mailboxName = mailboxName
        self.limit = limit
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

        switch step {
        case .greeting:
            // First untagged response is the server greeting → authenticate.
            send(.login(username: email, password: password), tag: loginTag, context: context)
            step = .login
        case .select:
            if case .mailboxData(.exists(let count)) = payload {
                messageCount = count
            }
        default:
            break
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
            sendFetchOrFinish(context: context)
        case fetchTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            settle(.success(messages.sorted { $0.id > $1.id }))
            send(.logout, tag: logoutTag, context: context)
            context.close(promise: nil)
        default:
            break
        }
    }

    private func handleFetch(_ response: FetchResponse) {
        switch response {
        case .start:
            current = PartialMessage()
        case .simpleAttribute(let attribute):
            apply(attribute)
        case .finish:
            if let message = current, let uid = message.uid, message.hasEnvelope {
                messages.append(
                    MailMessage(
                        id: uid,
                        uidValidity: selectedUIDValidity,
                        from: message.from,
                        replyTo: message.replyTo,
                        to: message.to,
                        subject: message.subject,
                        date: message.date,
                        inReplyTo: message.inReplyTo,
                        messageID: message.messageID
                    )
                )
            }
            current = nil
        default:
            break
        }
    }

    private func apply(_ attribute: MessageAttribute) {
        switch attribute {
        case .uid(let uid):
            current?.uid = uid.rawValue
        case .envelope(let envelope):
            applyEnvelope(envelope)
        default:
            break
        }
    }

    private func applyEnvelope(_ envelope: Envelope) {
        guard current != nil else { return }
        current?.hasEnvelope = true
        if let subject = envelope.subject {
            current?.subject = String(buffer: subject)
        }
        if let date = envelope.date {
            current?.date = String(date)
        }
        if let sender = envelope.from.first, let address = Self.address(from: sender) {
            current?.from = address
        }
        if let replyTo = envelope.reply.first, let address = Self.address(from: replyTo) {
            current?.replyTo = address
        }
        current?.to = envelope.to.compactMap(Self.address(from:))
        if let inReplyTo = envelope.inReplyTo {
            current?.inReplyTo = String(inReplyTo)
        }
        if let messageID = envelope.messageID {
            current?.messageID = String(messageID)
        }
    }

    // MARK: - Commands

    private func sendFetchOrFinish(context: ChannelHandlerContext) {
        guard messageCount > 0 else {
            settle(.success([]))
            send(.logout, tag: logoutTag, context: context)
            context.close(promise: nil)
            return
        }
        let upper = UInt32(messageCount)
        let lower = messageCount > limit ? UInt32(messageCount - limit + 1) : 1
        let range = MessageIdentifierRange<SequenceNumber>(
            SequenceNumber(rawValue: lower)...SequenceNumber(rawValue: upper)
        )
        let set = MessageIdentifierSetNonEmpty(range: range)
        send(.fetch(.set(set), [.uid, .envelope], []), tag: fetchTag, context: context)
        step = .fetch
    }

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

    private func settle(_ result: Result<[MailMessage], Error>) {
        guard !settled else { return }
        settled = true
        complete(result)
    }

    private static func address(from element: EmailAddressListElement) -> MailAddress? {
        guard case .singleAddress(let address) = element else { return nil }
        guard let mailbox = address.mailbox, let host = address.host else { return nil }
        let email = "\(String(buffer: mailbox))@\(String(buffer: host))"
        let name = address.personName.map { String(buffer: $0) }
        return MailAddress(name: name, email: email)
    }
}
