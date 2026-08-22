import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "ReplyWorthiness")

/// Reply-worthiness gating on `AppState` (item 17): the watcher runs this before
/// the LLM draft call so obvious non-replyable mail (no-reply senders, bulk/list
/// mail, automated notifications, calendar invites) never costs a draft. The
/// decision logic itself lives in the pure `ReplyWorthiness` evaluator; this file
/// gathers the signals, records skips, and provides the user override.
extension AppState {

    /// Judges `message` and returns the skip reason, or `nil` when it is worth a
    /// draft. Checks the decisive sender signals (both `From` and `Reply-To`)
    /// before fetching the bounded header fields the ENVELOPE lacks; if that fetch
    /// fails, evaluation falls back to sender-only signals.
    func replyWorthinessSkipReason(
        _ message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async -> ReplyWorthinessReason? {
        // Judge BOTH the `From` and `Reply-To` addresses (item 66): an automated
        // `From` (e.g. GitHub's `notifications@github.com`) must be caught even
        // when the routable `Reply-To` (`reply+…@reply.github.com`) looks human.
        let senderEmails = [message.from?.email, message.replyTo?.email]
        let senderOnly = ReplyWorthinessSignals(senderEmails: senderEmails)
        if let skipReason = ReplyWorthiness.evaluate(senderOnly).skipReason { return skipReason }

        let headers = await fetchReplyWorthinessHeaders(message, credentials: credentials, mailbox: mailbox)
        let signals = ReplyWorthinessSignals(senderEmails: senderEmails, headers: headers)
        return ReplyWorthiness.evaluate(signals).skipReason
    }

    /// Best-effort header-fields fetch for the worthiness check. Never throws:
    /// on any failure it returns empty fields so the caller degrades to
    /// sender-only evaluation rather than blocking the poll.
    private func fetchReplyWorthinessHeaders(
        _ message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async -> MailHeaderFields {
        do {
            return try await mailProvider.fetchHeaderFields(
                credentials,
                mailbox: mailbox,
                uid: message.id,
                expectedUIDValidity: message.uidValidity
            )
        } catch {
            logger.error("Reply-worthiness header fetch failed; evaluating sender only: \(error.localizedDescription)")
            return MailHeaderFields()
        }
    }

    // MARK: - Skip log

    /// Records a skipped message on the bounded, observable skip log (newest
    /// first). De-dupes by identity so the same message never appears twice.
    func recordSkip(
        _ message: MailMessage,
        reason: ReplyWorthinessReason,
        account: String,
        mailbox: Mailbox
    ) {
        let entry = SkippedMessage(
            message: message,
            mailbox: mailbox,
            account: account,
            reason: reason
        )
        skippedMessageIDs.insert(entry.id)
        skippedMessageReasonsByID[entry.id] = reason
        skippedMessages.removeAll { $0.id == entry.id }
        skippedMessages.insert(entry, at: 0)
        if skippedMessages.count > skippedMessageLogLimit {
            skippedMessages.removeLast(skippedMessages.count - skippedMessageLogLimit)
        }
        // The in-memory override entry above carries the full message for "Draft
        // anyway"; the activity log records the skip durably as metadata only, so
        // it survives restart even though the override entry does not (item 21,
        // closing item 17's deferred "skip reasons visible in the activity log").
        recordSkipActivity(for: entry)
        logger.info("Recorded skipped message (\(reason.rawValue, privacy: .public)); \(self.skippedMessages.count) visible entries")
    }

    /// Removes a single entry from the skip log.
    func removeSkippedMessage(_ entry: SkippedMessage) {
        skippedMessages.removeAll { $0.id == entry.id }
        skippedMessageIDs.remove(entry.id)
        skippedMessageReasonsByID.removeValue(forKey: entry.id)
    }

    /// Clears the whole skip log.
    func clearSkippedMessages() {
        skippedMessages.removeAll()
        skippedMessageIDs.removeAll()
        skippedMessageReasonsByID.removeAll()
    }

    /// Dismisses a skipped entry and durably suppresses future watcher handling.
    func dismissSkippedMessage(_ entry: SkippedMessage) {
        dismissSkippedMessages([entry])
    }

    /// Dismisses all visible skipped entries and persists the acknowledgements.
    func dismissAllSkippedMessages() {
        dismissSkippedMessages(skippedMessages)
    }

    /// Whether a skipped entry already exists for the same account/mailbox UID.
    func hasSkippedMessage(_ message: MailMessage, account: String, mailbox: Mailbox) -> Bool {
        let entry = SkippedMessage(message: message, mailbox: mailbox, account: account, reason: .noReplySender)
        return skippedMessageIDs.contains(entry.id)
    }

    /// The retained reason for a skipped message identity, including entries that
    /// have rolled out of the visible skip log but still suppress repeat work.
    func skippedMessageReason(_ message: MailMessage, account: String, mailbox: Mailbox) -> ReplyWorthinessReason? {
        let entry = SkippedMessage(message: message, mailbox: mailbox, account: account, reason: .noReplySender)
        return skippedMessageReasonsByID[entry.id]
    }

    /// Removes a skipped identity for a message that is being reconsidered by a
    /// sender-rule edit.
    func removeSkippedMessage(_ message: MailMessage, account: String, mailbox: Mailbox) {
        let entry = SkippedMessage(message: message, mailbox: mailbox, account: account, reason: .noReplySender)
        removeSkippedMessage(entry)
    }

    private func dismissSkippedMessages(_ entries: [SkippedMessage]) {
        guard !entries.isEmpty else { return }
        let entryIDs = Set(entries.map(\.id))
        for entry in entries {
            processedMessages.insert(entry.message, account: entry.account, mailbox: entry.mailbox)
        }
        persistence.saveProcessedMessages(processedMessages)
        skippedMessages.removeAll { entryIDs.contains($0.id) }
        skippedMessageIDs.subtract(entryIDs)
        for entryID in entryIDs {
            skippedMessageReasonsByID.removeValue(forKey: entryID)
        }
    }

    // MARK: - Override

    /// Forces a draft for a message the worthiness gate skipped. Routes through
    /// the normal draft pipeline (`draftAndEnqueue`), bypassing only the
    /// worthiness check, then marks the message handled and drops it from the
    /// skip log. `requireWatching` is `false` so the override works from the skip
    /// log regardless of watch state.
    @discardableResult
    func forceDraftSkippedMessage(_ entry: SkippedMessage) async -> Bool {
        approvalError = nil

        let credentials = mailCredentials
        guard credentials.isComplete else {
            approvalError = "Connect an email account first."
            return false
        }
        guard credentials.email.caseInsensitiveCompare(entry.account) == .orderedSame else {
            approvalError = "That message belongs to a different account than the one connected."
            return false
        }
        guard canGenerateDraft else {
            approvalError = "Connect an AI provider first."
            return false
        }

        do {
            let enqueued = try await draftAndEnqueue(
                entry.message,
                mailbox: entry.mailbox,
                requireWatching: false
            )
            guard enqueued else { return false }
            markProcessed(entry.message, account: credentials.email, mailbox: entry.mailbox)
            removeSkippedMessage(entry)
            return true
        } catch {
            approvalError = Self.draftMessage(for: error)
            logger.error("Force-draft of skipped message failed: \(error.localizedDescription)")
            return false
        }
    }
}
