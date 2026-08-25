import Foundation
import NIOCore
import NIOIMAP

/// Drives the bulk-cleanup conversation:
///
/// `LOGIN → SELECT → SEARCH sequence windows → FETCH UIDs → [sample FETCH |
/// UID STORE/MOVE in batches] → LOGOUT`
///
/// Selection is deliberately completed before any mutation: a `UID MOVE`
/// removes messages and renumbers the sequence space, which would corrupt a
/// scan still walking that space.
final class IMAPBulkCleanupHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    enum Step {
        case greeting, login, select, search, resolve, validate, sample, apply, done
    }

    /// Accumulates one FETCH response; `IMAPBulkCleanupHandler+Envelope` fills it.
    struct PartialMessage {
        var sequenceNumber: UInt32?
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
    let mailboxName: String
    let destinationName: String?
    private let request: IMAPBulkCleanupRequest
    let complete: @Sendable (Result<IMAPBulkOutcome, Error>) -> Void

    private var criteria: MailSearchCriteria { request.criteria }
    var action: MailBulkAction? { request.action }
    private var sampleLimit: Int { request.sampleLimit }
    private var selectionCap: Int { request.selectionCap }
    var onProgress: (@Sendable (MailBulkProgress) -> Void)? { request.onProgress }
    private var hasUnscannedSelectionWindows: Bool { windowIndex < windows.count }
    private var liveSelectionCriteria: MailSearchCriteria? {
        guard action == .markRead else { return criteria }
        return criteria.markReadCandidateCriteria()
    }

    private let loginTag = "A1"
    private let selectTag = "A2"
    private let sampleTag = "A3"
    private let logoutTag = "A4"

    var step: Step = .greeting
    var settled = false
    var messageCount = 0
    var selectedUIDValidity: UInt32?

    var windows: [(lower: UInt32, upper: UInt32)] = []
    var windowIndex = 0
    var pendingSequenceNumbers: [UInt32] = []
    var matchedUIDs: [UInt32] = []
    /// `matchedUIDs.count` at the start of the current window's resolve, so
    /// per-window resolved counts can be logged (item 49 diagnosis).
    var matchedUIDsAtWindowStart = 0
    private var isPartial = false

    var batches: [[UInt32]] = []
    var batchIndex = 0
    var currentBatchUIDs: [UInt32] = []
    var applyTotal = 0
    var affectedCount = 0

    var sample: [MailMessage] = []
    var current: PartialMessage?

    init(
        email: String,
        password: String,
        mailboxName: String,
        destinationName: String?,
        request: IMAPBulkCleanupRequest,
        complete: @escaping @Sendable (Result<IMAPBulkOutcome, Error>) -> Void
    ) {
        self.email = email
        self.password = password
        self.mailboxName = mailboxName
        self.destinationName = destinationName
        self.request = request
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

    /// Windowed selection exists precisely so the 8 KB frame cap is never hit,
    /// but map it anyway: if a window ever did overflow, "narrow your filter" is
    /// far more useful than a raw decoder error (item 45).
    static func mapped(_ error: Error) -> MailError {
        if error is ByteToMessageDecoderError.PayloadTooLargeError {
            return .resultTooLarge
        }
        return .connectionFailed(String(describing: error))
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle(.failure(MailError.connectionFailed("The connection closed before the cleanup completed.")))
        context.fireChannelInactive()
    }

    // MARK: - Response handling

    private func handleUntagged(_ payload: ResponsePayload, context: ChannelHandlerContext) {
        captureUIDValidity(from: payload)

        if isMailboxMutation(payload), step == .search || step == .resolve {
            failMailboxChangedDuringSelection(context: context)
            return
        }

        switch step {
        case .greeting:
            send(.login(username: email, password: password), tag: loginTag, context: context)
            step = .login
        case .select:
            if case .mailboxData(.exists(let count)) = payload {
                messageCount = count
            }
        case .search:
            if case .mailboxData(.search(let ids, _)) = payload {
                pendingSequenceNumbers.append(contentsOf: ids.map(\.rawValue))
            }
        case .validate:
            if case .mailboxData(.search(let ids, _)) = payload {
                currentBatchUIDs.append(contentsOf: ids.map(\.rawValue))
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
            if let selection = request.selection, action != nil {
                beginProvidedSelection(selection, context: context)
            } else {
                beginSelection(context: context)
            }
        case sampleTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            settlePreview(context: context)
        default:
            handleOperationTagged(tagged, context: context)
        }
    }

    private func handleOperationTagged(_ tagged: TaggedResponse, context: ChannelHandlerContext) {
        guard isOK(tagged.state) else { return failTagged(tagged.state) }

        switch step {
        case .search:
            logWindowSearch()
            resolveCurrentWindow(context: context)
        case .resolve:
            logWindowResolve()
            pendingSequenceNumbers.removeAll()
            windowIndex += 1
            continueSelection(context: context)
        case .validate:
            mutateCurrentBatch(context: context)
        case .apply:
            // Guard the index rather than trusting tag ordering: an
            // unsolicited or duplicated tagged response would otherwise
            // index past the last batch and crash the app.
            guard batchIndex < batches.count else { return }
            affectedCount += currentBatchUIDs.count
            onProgress?(MailBulkProgress(processed: affectedCount, total: applyTotal))
            currentBatchUIDs.removeAll()
            batchIndex += 1
            continueApply(context: context)
        default:
            break
        }
    }

    // MARK: - Selection

    private func beginSelection(context: ChannelHandlerContext) {
        guard liveSelectionCriteria != nil else {
            finishSelection(context: context)
            return
        }
        windows = SequenceWindow.windows(total: messageCount)
        windowIndex = 0
        logSelectionStart()
        step = .search
        continueSelection(context: context)
    }

    private func isMailboxMutation(_ payload: ResponsePayload) -> Bool {
        switch payload {
        case .messageData(.expunge), .messageData(.vanished), .messageData(.vanishedEarlier):
            return true
        default:
            return false
        }
    }

    private func failMailboxChangedDuringSelection(context: ChannelHandlerContext) {
        settle(.failure(MailError.commandFailed(
            "The mailbox changed while preparing the cleanup. Preview again before running cleanup."
        )))
        finish(context: context)
    }

    /// Applies the exact UID set approved by a preview instead of rerunning the
    /// live filter, so newly arrived matching mail is not swept into the run.
    /// `finishSelection` still de-duplicates and enforces `selectionCap` for
    /// supplied UID sets before anything is mutated.
    private func beginProvidedSelection(
        _ selection: MailBulkSelection,
        context: ChannelHandlerContext
    ) {
        if let expectedUIDValidity = selection.uidValidity {
            guard let selectedUIDValidity, expectedUIDValidity == selectedUIDValidity else {
                settle(.failure(MailError.commandFailed(
                    "The mailbox changed since the preview. Preview again before running cleanup."
                )))
                return finish(context: context)
            }
        }
        matchedUIDs = selection.uids
        finishSelection(context: context)
    }

    /// Issues the next bounded `SEARCH`, or moves on once every window has been
    /// scanned or the selection cap is reached.
    private func continueSelection(context: ChannelHandlerContext) {
        if matchedUIDs.count >= selectionCap {
            isPartial = isPartial || hasUnscannedSelectionWindows
            finishSelection(context: context)
            return
        }
        guard windowIndex < windows.count else {
            finishSelection(context: context)
            return
        }
        let window = windows[windowIndex]
        let range = MessageIdentifierRange<SequenceNumber>(
            SequenceNumber(rawValue: window.lower)...SequenceNumber(rawValue: window.upper)
        )
        let key: SearchKey = .and([
            .sequenceNumbers(.range(range)),
            IMAPSearchHandler.searchKey(for: liveSelectionCriteria ?? criteria)
        ])
        pendingSequenceNumbers.removeAll()
        step = .search
        send(.search(key: key), tag: "S\(windowIndex)", context: context)
    }

    private func resolveCurrentWindow(context: ChannelHandlerContext) {
        guard let set = Self.sequenceIdentifierSet(for: pendingSequenceNumbers) else {
            windowIndex += 1
            continueSelection(context: context)
            return
        }
        matchedUIDsAtWindowStart = matchedUIDs.count
        step = .resolve
        send(.fetch(.set(set), [.uid], []), tag: "F\(windowIndex)", context: context)
    }

    func recordResolvedUID(_ uid: UInt32, for sequenceNumber: UInt32?) {
        guard let sequenceNumber, pendingSequenceNumbers.contains(sequenceNumber) else { return }
        matchedUIDs.append(uid)
    }

    /// Selection is complete: either sample the matches (preview) or start
    /// applying the action in bounded batches.
    private func finishSelection(context: ChannelHandlerContext) {
        // Newest first, and never act on more than the user was shown.
        let rawCount = matchedUIDs.count
        matchedUIDs = Array(Set(matchedUIDs)).sorted(by: >)
        logSelectionDone(rawCount: rawCount)
        if matchedUIDs.count > selectionCap {
            isPartial = true
            matchedUIDs = Array(matchedUIDs.prefix(selectionCap))
        }

        guard action != nil else { return beginSample(context: context) }
        guard !matchedUIDs.isEmpty else { return settleApplied(context: context) }
        beginApply(context: context)
    }

    private func beginApply(context: ChannelHandlerContext) {
        batches = SequenceWindow.batches(matchedUIDs)
        batchIndex = 0
        applyTotal = matchedUIDs.count
        currentBatchUIDs.removeAll()
        step = .apply
        continueApply(context: context)
    }

    private func beginSample(context: ChannelHandlerContext) {
        let sampleUIDs = Array(matchedUIDs.prefix(max(0, sampleLimit)))
        guard let set = Self.identifierSet(for: sampleUIDs) else {
            return settlePreview(context: context)
        }
        step = .sample
        send(.uidFetch(.set(set), [.uid, .envelope], []), tag: sampleTag, context: context)
    }

    // MARK: - Settling

    private func settlePreview(context: ChannelHandlerContext) {
        settle(.success(IMAPBulkOutcome(
            matchCount: matchedUIDs.count,
            sample: sample.sorted { $0.id > $1.id },
            isPartial: isPartial,
            selection: MailBulkSelection(uidValidity: selectedUIDValidity, uids: matchedUIDs),
            affectedCount: 0
        )))
        finish(context: context)
    }

    func settleApplied(context: ChannelHandlerContext) {
        settle(.success(IMAPBulkOutcome(
            matchCount: matchedUIDs.count,
            sample: [],
            isPartial: isPartial,
            selection: nil,
            affectedCount: affectedCount
        )))
        finish(context: context)
    }

    func finish(context: ChannelHandlerContext) {
        step = .done
        send(.logout, tag: logoutTag, context: context)
        context.close(promise: nil)
    }

    func send(_ command: Command, tag: String, context: ChannelHandlerContext) {
        let part = CommandStreamPart.tagged(TaggedCommand(tag: tag, command: command))
        context.writeAndFlush(NIOAny(IMAPClientHandler.Message.part(part)), promise: nil)
    }
}
