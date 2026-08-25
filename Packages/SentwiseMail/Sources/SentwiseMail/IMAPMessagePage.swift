import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

/// Pure paging math for the sequence-number-based "recent messages" view.
///
/// IMAP sequence numbers are contiguous `1...EXISTS` in arrival order, so the
/// newest messages have the highest numbers. Paging newest-first means fetching
/// a bounded sequence range per page — never asking the server for every UID at
/// once (which overflows NIO-IMAP's 8 KB frame cap on large mailboxes).
enum SequencePageRange {
    /// The 1-based sequence range `[lower, upper]` to FETCH for the page at
    /// `offset` (0 = newest page) of `total` messages, each page up to `limit`.
    /// Returns `nil` when the page is empty (no messages, or `offset` past the
    /// end).
    static func forPage(total: Int, offset: Int, limit: Int) -> (lower: UInt32, upper: UInt32)? {
        guard total > 0, limit > 0, offset >= 0, offset < total else { return nil }
        let upper = total - offset
        let lower = max(1, upper - limit + 1)
        return (UInt32(lower), UInt32(upper))
    }

    /// Whether more pages remain after the page at `offset`.
    static func hasMore(total: Int, offset: Int, limit: Int) -> Bool {
        guard total > 0, limit > 0, offset >= 0 else { return false }
        return offset + limit < total
    }
}

extension IMAPMailProvider {
    /// Fetches one page of a mailbox's messages by sequence number (newest
    /// first), returning the page plus the mailbox's total message count.
    ///
    /// Drives `LOGIN → SELECT → FETCH (bounded sequence range) → LOGOUT`. Unlike
    /// `searchMessages`, this issues no `UID SEARCH`, so the server never returns
    /// an unbounded list of UIDs — the "recent mail" view stays usable on
    /// mailboxes of any size (item 45).
    public func fetchMessagePage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult {
        try await fetchMessagePage(
            credentials,
            mailbox: mailbox,
            offset: offset,
            limit: limit,
            snapshotMessageCount: nil
        )
    }

    public func fetchMessagePage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        offset: Int,
        limit: Int,
        snapshotMessageCount: Int?
    ) async throws -> MailSearchResult {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }
        guard limit > 0, offset >= 0 else { return .empty(offset: max(0, offset)) }

        let attempts = ChannelPromiseTracker<MailSearchResult>()
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
                    let handler = IMAPMessagePageHandler(
                        email: email,
                        password: password,
                        mailboxName: mailboxName,
                        offset: offset,
                        limit: limit,
                        snapshotMessageCount: snapshotMessageCount,
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
        guard let pageFuture = attempts.future(for: channel) else {
            try? await channel.close().get()
            throw MailError.connectionFailed("The mail connection could not start fetching.")
        }

        let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)
        }
        defer { timeoutTask.cancel() }

        do {
            let result = try await pageFuture.get()
            try? await channel.close().get()
            return result
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

/// Drives LOGIN → SELECT → FETCH (one bounded sequence range) → LOGOUT and
/// settles via `complete` with the page plus the total message count (`EXISTS`).
final class IMAPMessagePageHandler: ChannelInboundHandler {
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
    private let offset: Int
    private let limit: Int
    private let snapshotMessageCount: Int?
    private let complete: @Sendable (Result<MailSearchResult, Error>) -> Void

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
        offset: Int,
        limit: Int,
        snapshotMessageCount: Int?,
        complete: @escaping @Sendable (Result<MailSearchResult, Error>) -> Void
    ) {
        self.email = email
        self.password = password
        self.mailboxName = mailboxName
        self.offset = offset
        self.limit = limit
        self.snapshotMessageCount = snapshotMessageCount
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
            fetchPageOrFinish(context: context)
        case fetchTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            settleSuccess(context: context)
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

    /// After SELECT, FETCH the bounded sequence range for this page, or finish
    /// immediately when the mailbox is empty or the page is past the end.
    private func fetchPageOrFinish(context: ChannelHandlerContext) {
        let pageTotal = snapshotMessageCount ?? messageCount
        guard var range = SequencePageRange.forPage(total: pageTotal, offset: offset, limit: limit) else {
            settle(.success(MailSearchResult(
                messages: [], totalMatches: pageTotal, offset: offset, hasMore: false
            )))
            send(.logout, tag: logoutTag, context: context)
            context.close(promise: nil)
            return
        }
        range.upper = min(range.upper, UInt32(messageCount))
        guard range.lower <= range.upper else {
            settle(.success(MailSearchResult(
                messages: [],
                totalMatches: pageTotal,
                offset: offset,
                hasMore: SequencePageRange.hasMore(total: pageTotal, offset: offset, limit: limit)
            )))
            send(.logout, tag: logoutTag, context: context)
            context.close(promise: nil)
            return
        }
        let sequenceRange = MessageIdentifierRange<SequenceNumber>(
            SequenceNumber(rawValue: range.lower)...SequenceNumber(rawValue: range.upper)
        )
        let set = MessageIdentifierSetNonEmpty(range: sequenceRange)
        send(.fetch(.set(set), [.uid, .envelope], []), tag: fetchTag, context: context)
        step = .fetch
    }

    private func settleSuccess(context: ChannelHandlerContext) {
        settle(.success(MailSearchResult(
            messages: messages.sorted { $0.id > $1.id },
            totalMatches: snapshotMessageCount ?? messageCount,
            offset: offset,
            hasMore: SequencePageRange.hasMore(
                total: snapshotMessageCount ?? messageCount,
                offset: offset,
                limit: limit
            )
        )))
        step = .done
        send(.logout, tag: logoutTag, context: context)
        context.close(promise: nil)
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

    private func settle(_ result: Result<MailSearchResult, Error>) {
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
