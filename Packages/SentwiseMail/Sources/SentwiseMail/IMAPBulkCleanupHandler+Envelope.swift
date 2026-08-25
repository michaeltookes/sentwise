import Foundation
import NIOCore
import NIOIMAP

/// Envelope parsing and small helpers for `IMAPBulkCleanupHandler`. Split out
/// so the state machine that drives the IMAP conversation stays readable on its
/// own.
extension IMAPBulkCleanupHandler {

    func handleFetch(_ response: FetchResponse) {
        switch response {
        case .start(let sequenceNumber):
            current = PartialMessage(sequenceNumber: sequenceNumber.rawValue)
        case .startUID(let uid):
            current = PartialMessage(uid: uid.rawValue)
        case .simpleAttribute(let attribute):
            apply(attribute)
        case .finish:
            if let message = current, let uid = message.uid, step == .resolve {
                recordResolvedUID(uid, for: message.sequenceNumber)
            } else if let message = current, let uid = message.uid, message.hasEnvelope {
                sample.append(
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

    func apply(_ attribute: MessageAttribute) {
        switch attribute {
        case .uid(let uid):
            current?.uid = uid.rawValue
        case .envelope(let envelope):
            applyEnvelope(envelope)
        default:
            break
        }
    }

    func applyEnvelope(_ envelope: Envelope) {
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

    // MARK: - Helpers

    /// Builds a UID set for a STORE/MOVE/FETCH command. Contiguous UIDs collapse
    /// into ranges, keeping the command line short. Returns `nil` for an empty
    /// selection, which IMAP has no valid syntax for.
    static func identifierSet(for uids: [UInt32]) -> MessageIdentifierSetNonEmpty<UID>? {
        let ranges = uids.compactMap { raw -> MessageIdentifierRange<UID>? in
            guard let uid = UID(exactly: raw) else { return nil }
            return MessageIdentifierRange<UID>(uid...uid)
        }
        guard !ranges.isEmpty else { return nil }
        return MessageIdentifierSetNonEmpty(set: MessageIdentifierSet<UID>(ranges))
    }

    /// Builds a sequence-number set for the UID-resolution FETCH that follows
    /// each regular SEARCH window.
    static func sequenceIdentifierSet(for numbers: [UInt32]) -> MessageIdentifierSetNonEmpty<SequenceNumber>? {
        let ranges = numbers.compactMap { raw -> MessageIdentifierRange<SequenceNumber>? in
            guard let number = SequenceNumber(exactly: raw) else { return nil }
            return MessageIdentifierRange<SequenceNumber>(number...number)
        }
        guard !ranges.isEmpty else { return nil }
        return MessageIdentifierSetNonEmpty(set: MessageIdentifierSet<SequenceNumber>(ranges))
    }

    func isOK(_ state: TaggedResponse.State) -> Bool {
        if case .ok = state { return true }
        return false
    }

    func failTagged(_ state: TaggedResponse.State) {
        switch state {
        case .no(let text), .bad(let text):
            let error: MailError = step == .login
                ? .authenticationFailed(text.text)
                : .commandFailed(describe(text.text))
            settle(.failure(error))
        case .ok:
            break
        }
    }

    /// A server without the MOVE extension rejects `UID MOVE` with an opaque
    /// error; say what actually went wrong so the user isn't left guessing.
    func describe(_ text: String) -> String {
        guard step == .apply, destinationName != nil else { return text }
        return "\(text) (the server may not support moving messages in bulk)"
    }

    func captureUIDValidity(from payload: ResponsePayload) {
        guard case .conditionalState(.ok(let text)) = payload,
              case .some(.uidValidity(let value)) = text.code else {
            return
        }
        selectedUIDValidity = UInt32(value)
    }

    func captureUIDValidity(from state: TaggedResponse.State) {
        guard case .ok(let text) = state,
              case .some(.uidValidity(let value)) = text.code else {
            return
        }
        selectedUIDValidity = UInt32(value)
    }

    func settle(_ result: Result<IMAPBulkOutcome, Error>) {
        guard !settled else { return }
        settled = true
        complete(result)
    }

    static func address(from element: EmailAddressListElement) -> MailAddress? {
        guard case .singleAddress(let address) = element else { return nil }
        guard let mailbox = address.mailbox, let host = address.host else { return nil }
        let email = "\(String(buffer: mailbox))@\(String(buffer: host))"
        let name = address.personName.map { String(buffer: $0) }
        return MailAddress(name: name, email: email)
    }

    // MARK: - Diagnostics (item 49)

    func logSelectionStart() {
        IMAPDiagnosticLog.log(
            "bulk selection start: mailbox=\(mailboxName) EXISTS=\(messageCount) "
                + "windows=\(windows.count) (\(SequenceWindow.defaultSize)/window)"
        )
    }

    func logWindowSearch() {
        guard windowIndex < windows.count else { return }
        IMAPDiagnosticLog.log(
            "window \(windowIndex) \(windows[windowIndex]) SEARCH returned "
                + "\(pendingSequenceNumbers.count) sequence numbers"
        )
    }

    func logWindowResolve() {
        IMAPDiagnosticLog.log(
            "window \(windowIndex) resolved \(matchedUIDs.count - matchedUIDsAtWindowStart) UIDs "
                + "from \(pendingSequenceNumbers.count) sequence numbers "
                + "(cumulative matched=\(matchedUIDs.count))"
        )
    }

    func logSelectionDone(rawCount: Int) {
        IMAPDiagnosticLog.log(
            "bulk selection done: scanned \(windowIndex)/\(windows.count) windows, "
                + "raw matched=\(rawCount), unique matched=\(matchedUIDs.count)"
        )
    }
}
