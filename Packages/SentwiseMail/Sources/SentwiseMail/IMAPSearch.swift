import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

extension IMAPMailProvider {
    /// Searches a mailbox server-side and returns one page of results.
    ///
    /// Drives `LOGIN → SELECT → UID SEARCH → UID FETCH (envelopes) → LOGOUT`.
    /// The `SEARCH` runs on the server, so even very large mailboxes only ever
    /// return matching UIDs; a bounded page of those UIDs is then fetched.
    public func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }
        guard limit > 0 else { return .empty(offset: offset) }

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
                    let handler = IMAPSearchHandler(
                        email: email,
                        password: password,
                        mailboxName: mailboxName,
                        criteria: criteria,
                        offset: offset,
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
        guard let searchFuture = attempts.future(for: channel) else {
            try? await channel.close().get()
            throw MailError.connectionFailed("The mail connection could not start searching.")
        }

        let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)
        }
        defer { timeoutTask.cancel() }

        do {
            let result = try await searchFuture.get()
            try? await channel.close().get()
            return result
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

/// Pure paging over the matched UID set — split out so the offset/limit and
/// "newest first" ordering can be unit-tested without a channel.
enum MailSearchPaging {
    /// Returns the requested page of `matchedUIDs` newest first (highest UID
    /// first), the total match count, and whether more pages remain. A negative
    /// or out-of-range `offset`, or a non-positive `limit`, yields an empty page.
    static func page(
        matchedUIDs: [UInt32],
        offset: Int,
        limit: Int
    ) -> (page: [UInt32], total: Int, hasMore: Bool) {
        let total = matchedUIDs.count
        guard limit > 0, offset >= 0, offset < total else {
            return ([], total, false)
        }
        let sortedDesc = matchedUIDs.sorted(by: >)
        let end = min(offset + limit, total)
        return (Array(sortedDesc[offset..<end]), total, end < total)
    }
}

/// Drives LOGIN → SELECT → UID SEARCH → UID FETCH (envelope) → LOGOUT and
/// completes `promise` with one page of results, newest first.
final class IMAPSearchHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    private enum Step {
        case greeting, login, select, search, fetch, done
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
    private let criteria: MailSearchCriteria
    private let offset: Int
    private let limit: Int
    private let calendar: Calendar
    private let complete: @Sendable (Result<MailSearchResult, Error>) -> Void

    private let loginTag = "A1"
    private let selectTag = "A2"
    private let searchTag = "A3"
    private let fetchTag = "A4"
    private let logoutTag = "A5"

    private var step: Step = .greeting
    private var settled = false
    private var selectedUIDValidity: UInt32?
    private var matchedUIDs: [UInt32] = []
    private var totalMatches = 0
    private var hasMore = false
    private var messages: [MailMessage] = []
    private var current: PartialMessage?

    init(
        email: String,
        password: String,
        mailboxName: String,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int,
        calendar: Calendar = .current,
        complete: @escaping @Sendable (Result<MailSearchResult, Error>) -> Void
    ) {
        self.email = email
        self.password = password
        self.mailboxName = mailboxName
        self.criteria = criteria
        self.offset = offset
        self.limit = limit
        self.calendar = calendar
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
        settle(.failure(Self.mapped(error)))
        context.close(promise: nil)
    }

    /// A too-many-results overflow (the `* SEARCH` line exceeded NIO-IMAP's frame
    /// cap) surfaces as a decoder `PayloadTooLargeError`; map it to a clear,
    /// actionable error rather than a generic connection failure (item 45).
    static func mapped(_ error: Error) -> MailError {
        if error is ByteToMessageDecoderError.PayloadTooLargeError {
            return .resultTooLarge
        }
        return .connectionFailed(String(describing: error))
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle(.failure(MailError.connectionFailed("The connection closed before the search completed.")))
        context.fireChannelInactive()
    }

    // MARK: - Response handling

    private func handleUntagged(_ payload: ResponsePayload, context: ChannelHandlerContext) {
        captureUIDValidity(from: payload)

        switch step {
        case .greeting:
            send(.login(username: email, password: password), tag: loginTag, context: context)
            step = .login
        case .search:
            if case .mailboxData(.search(let ids, _)) = payload {
                matchedUIDs.append(contentsOf: ids.map { $0.rawValue })
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
            send(.uidSearch(key: Self.searchKey(for: criteria, calendar: calendar)), tag: searchTag, context: context)
            step = .search
        case searchTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
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

    /// After SEARCH completes, page the matched UIDs and either FETCH that page
    /// or finish immediately (empty match set / offset past the end).
    private func fetchPageOrFinish(context: ChannelHandlerContext) {
        let (page, total, more) = MailSearchPaging.page(
            matchedUIDs: matchedUIDs, offset: offset, limit: limit
        )
        totalMatches = total
        hasMore = more

        guard !page.isEmpty else {
            settle(.success(MailSearchResult(
                messages: [], totalMatches: total, offset: offset, hasMore: more
            )))
            send(.logout, tag: logoutTag, context: context)
            context.close(promise: nil)
            return
        }

        let ranges = page.map { MessageIdentifierRange<UID>(UID(rawValue: $0)) }
        let set = MessageIdentifierSet<UID>(ranges)
        guard let nonEmpty = MessageIdentifierSetNonEmpty(set: set) else {
            settle(.success(MailSearchResult(
                messages: [], totalMatches: total, offset: offset, hasMore: more
            )))
            send(.logout, tag: logoutTag, context: context)
            context.close(promise: nil)
            return
        }

        send(.uidFetch(.set(nonEmpty), [.uid, .envelope], []), tag: fetchTag, context: context)
        step = .fetch
    }

    private func settleSuccess(context: ChannelHandlerContext) {
        settle(.success(MailSearchResult(
            messages: messages.sorted { $0.id > $1.id },
            totalMatches: totalMatches,
            offset: offset,
            hasMore: hasMore
        )))
        step = .done
        send(.logout, tag: logoutTag, context: context)
        context.close(promise: nil)
    }

    private func send(_ command: Command, tag: String, context: ChannelHandlerContext) {
        let part = CommandStreamPart.tagged(TaggedCommand(tag: tag, command: command))
        context.writeAndFlush(NIOAny(IMAPClientHandler.Message.part(part)), promise: nil)
    }

    // MARK: - Criteria encoding

    /// Translates search criteria into a single IMAP `SearchKey` (fields AND-ed;
    /// `.all` when nothing is set). Blank text fields are dropped.
    static func searchKey(for criteria: MailSearchCriteria, calendar: Calendar = .current) -> SearchKey {
        let keys = textKeys(for: criteria) + dateKeys(for: criteria, calendar: calendar) + stateKeys(for: criteria)
            + uidKeys(for: criteria)
        switch keys.count {
        case 0: return .all
        case 1: return keys[0]
        default: return .and(keys)
        }
    }

    private static func textKeys(for criteria: MailSearchCriteria) -> [SearchKey] {
        var keys: [SearchKey] = []
        if let text = trimmed(criteria.text) { keys.append(.text(ByteBuffer(string: text))) }
        if let from = trimmed(criteria.from) { keys.append(.from(ByteBuffer(string: from))) }
        if let subject = trimmed(criteria.subject) { keys.append(.subject(ByteBuffer(string: subject))) }
        for header in criteria.headers {
            guard let field = trimmed(header.field), let value = trimmed(header.value) else { continue }
            keys.append(.header(field, ByteBuffer(string: value)))
        }
        return keys
    }

    private static func dateKeys(for criteria: MailSearchCriteria, calendar: Calendar) -> [SearchKey] {
        var keys: [SearchKey] = []
        if let since = criteria.since, let day = calendarDay(from: since, calendar: calendar) {
            keys.append(.since(day))
        }
        if let before = criteria.before, let day = calendarDay(from: before, calendar: calendar) {
            keys.append(.before(day))
        }
        return keys
    }

    private static func stateKeys(for criteria: MailSearchCriteria) -> [SearchKey] {
        var keys: [SearchKey] = []
        switch criteria.readState {
        case .any: break
        case .unreadOnly: keys.append(.unseen)
        case .readOnly: keys.append(.seen)
        }
        if criteria.flaggedOnly { keys.append(.flagged) }
        return keys
    }

    private static func uidKeys(for criteria: MailSearchCriteria) -> [SearchKey] {
        guard let maximumUID = criteria.maximumUID, let upperBound = UID(exactly: maximumUID) else {
            return []
        }
        return [.uid(.range(...upperBound))]
    }

    static func calendarDay(from date: Date, calendar: Calendar = .current) -> IMAPCalendarDay? {
        let components = imapDateCalendar(from: calendar).dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        return IMAPCalendarDay(year: year, month: month, day: day)
    }

    private static func imapDateCalendar(from calendar: Calendar) -> Calendar {
        var imapCalendar = Calendar(identifier: .gregorian)
        imapCalendar.timeZone = calendar.timeZone
        return imapCalendar
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
