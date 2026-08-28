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
        // Judge BOTH the `From` and `Reply-To` addresses (item 66), preserving
        // their roles so a real `Reply-To` can outweigh a generic platform `From`.
        let senderOnly = ReplyWorthinessSignals(
            fromEmail: message.from?.email,
            replyToEmail: message.replyTo?.email
        )
        if let skipReason = ReplyWorthiness.evaluate(senderOnly).skipReason { return skipReason }

        let headers = await fetchReplyWorthinessHeaders(message, credentials: credentials, mailbox: mailbox)
        let signals = ReplyWorthinessSignals(
            fromEmail: message.from?.email,
            replyToEmail: message.replyTo?.email,
            headers: headers
        )
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
        let entry = skippedEntry(message, reason: reason, account: account, mailbox: mailbox)
        do {
            try recordSkipSync(entry)
        } catch {
            logger.error("Failed to persist skipped message: \(error.localizedDescription)")
            recordSkipInMemory(entry)
        }
    }

    /// Records a skipped message only after its recoverable entry is durable.
    /// Internal so the pre-gate draft sweep can preserve its recovery path before
    /// deleting the corresponding pending draft.
    @discardableResult
    func recordSkipSync(
        _ message: MailMessage,
        reason: ReplyWorthinessReason,
        account: String,
        mailbox: Mailbox,
        preservesRecoveryWhenProcessed: Bool = false,
        recordActivity: Bool = true
    ) throws -> SkippedMessage {
        let entry = skippedEntry(
            message,
            reason: reason,
            account: account,
            mailbox: mailbox,
            preservesRecoveryWhenProcessed: preservesRecoveryWhenProcessed
        )
        try recordSkipSync(entry, recordActivity: recordActivity)
        return entry
    }

    private func recordSkipSync(_ entry: SkippedMessage, recordActivity: Bool = true) throws {
        let persistedMessages = persistedSkippedMessages(recording: entry)
        try persistence.saveSkippedMessagesSync(persistedMessages)
        let accountEmail = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.account : mailEmail
        let visibleMessages = Self.visibleSkippedMessages(
            from: persistedMessages,
            accountEmail: accountEmail,
            limit: skippedMessageLogLimit
        )
        recordSkipInMemory(entry, visibleMessages: visibleMessages, recordActivity: recordActivity)
    }

    /// Removes a single entry from the skip log.
    func removeSkippedMessage(_ entry: SkippedMessage) {
        do {
            try removeSkippedMessageSync(entry)
        } catch {
            logger.error("Failed to persist skipped-message removal: \(error.localizedDescription)")
        }
    }

    /// Removes a skip entry durably before updating in-memory state.
    func removeSkippedMessageSync(_ entry: SkippedMessage) throws {
        let persistedMessages = persistence.loadSkippedMessages().filter { $0.id != entry.id }
        try persistence.saveSkippedMessagesSync(persistedMessages)
        removeSkippedMessageFromMemory(entry)
    }

    /// Clears the whole skip log.
    func clearSkippedMessages() {
        do {
            try clearSkippedMessagesSync()
        } catch {
            logger.error("Failed to persist skipped-message clear: \(error.localizedDescription)")
        }
    }

    /// Clears the skip log durably before updating in-memory state.
    func clearSkippedMessagesSync() throws {
        let entryIDs = Set(skippedMessages.map(\.id))
        guard !entryIDs.isEmpty else { return }
        let persistedMessages = persistence.loadSkippedMessages().filter { !entryIDs.contains($0.id) }
        try persistence.saveSkippedMessagesSync(persistedMessages)
        clearSkippedMessageState()
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
        let visibleMessages = skippedMessages.filter { !entryIDs.contains($0.id) }
        do {
            let persistedMessages = persistence.loadSkippedMessages().filter { !entryIDs.contains($0.id) }
            try persistence.saveSkippedMessagesSync(persistedMessages)
            skippedMessages = visibleMessages
            skippedMessageIDs.subtract(entryIDs)
            for entryID in entryIDs {
                skippedMessageReasonsByID.removeValue(forKey: entryID)
            }
        } catch {
            logger.error("Failed to persist skipped-message dismissal: \(error.localizedDescription)")
        }
    }

    private func persistedSkippedMessages(recording entry: SkippedMessage) -> [SkippedMessage] {
        var persistedMessages = persistence.loadSkippedMessages()
        let persistedIDs = Set(persistedMessages.map(\.id))
        persistedMessages.append(contentsOf: skippedMessages.filter { !persistedIDs.contains($0.id) })
        persistedMessages.removeAll { $0.id == entry.id }
        persistedMessages.insert(entry, at: 0)
        return Self.boundedPersistedSkippedMessages(
            persistedMessages,
            regularLimitPerAccount: skippedMessageLogLimit
        )
    }

    private func visibleSkippedMessages(recording entry: SkippedMessage) -> [SkippedMessage] {
        let accountEmail = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.account : mailEmail
        var visibleMessages = Self.visibleSkippedMessages(
            from: skippedMessages,
            accountEmail: accountEmail,
            limit: skippedMessageLogLimit
        )
        visibleMessages.removeAll { $0.id == entry.id }
        visibleMessages.insert(entry, at: 0)
        return Self.boundedPersistedSkippedMessages(
            visibleMessages,
            regularLimitPerAccount: skippedMessageLogLimit
        )
    }

    private func skippedEntry(
        _ message: MailMessage,
        reason: ReplyWorthinessReason,
        account: String,
        mailbox: Mailbox,
        preservesRecoveryWhenProcessed: Bool = false
    ) -> SkippedMessage {
        SkippedMessage(
            message: message,
            mailbox: mailbox,
            account: account,
            reason: reason,
            preservesRecoveryWhenProcessed: preservesRecoveryWhenProcessed
        )
    }

    private func recordSkipInMemory(
        _ entry: SkippedMessage,
        visibleMessages: [SkippedMessage]? = nil,
        recordActivity: Bool = true
    ) {
        skippedMessageIDs.insert(entry.id)
        skippedMessageReasonsByID[entry.id] = entry.reason
        skippedMessages = visibleMessages ?? visibleSkippedMessages(recording: entry)
        // The visible skip entry carries the full message for "Draft anyway".
        // When the skipped-message write succeeds, that same recovery entry is
        // available after restart; activity history records metadata only.
        if recordActivity {
            recordSkipActivity(for: entry)
        }
        logger.info("Recorded skipped message (\(entry.reason.rawValue, privacy: .public)); \(self.skippedMessages.count) visible entries")
    }

    private func removeSkippedMessageFromMemory(_ entry: SkippedMessage) {
        skippedMessages.removeAll { $0.id == entry.id }
        skippedMessageIDs.remove(entry.id)
        skippedMessageReasonsByID.removeValue(forKey: entry.id)
    }

    private func clearSkippedMessageState() {
        skippedMessages.removeAll()
        skippedMessageIDs.removeAll()
        skippedMessageReasonsByID.removeAll()
    }

    static func boundedPersistedSkippedMessages(
        _ messages: [SkippedMessage],
        regularLimitPerAccount limit: Int
    ) -> [SkippedMessage] {
        var visibleRegularCounts: [String: Int] = [:]
        var retained: [SkippedMessage] = []
        var retainedIDs: Set<String> = []

        for entry in messages {
            guard retainedIDs.insert(entry.id).inserted else { continue }
            guard !entry.preservesRecoveryWhenProcessed else {
                retained.append(entry)
                continue
            }

            let account = skippedAccountKey(entry.account) ?? ""
            let visibleCount = visibleRegularCounts[account, default: 0]
            guard visibleCount < limit else { continue }
            visibleRegularCounts[account] = visibleCount + 1
            retained.append(entry)
        }

        return retained
    }

    static func visibleSkippedMessages(
        from messages: [SkippedMessage],
        accountEmail: String?,
        limit: Int
    ) -> [SkippedMessage] {
        guard let account = skippedAccountKey(accountEmail) else { return [] }
        return boundedPersistedSkippedMessages(
            messages.filter { skippedAccountKey($0.account) == account },
            regularLimitPerAccount: limit
        )
    }

    private static func skippedAccountKey(_ account: String?) -> String? {
        let normalized = (account ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
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
            if !hasPendingReplyWorthinessOverride(for: entry, account: credentials.email) {
                let enqueued = try await draftAndEnqueue(
                    entry.message,
                    mailbox: entry.mailbox,
                    requireWatching: false,
                    replyWorthinessOverride: true
                )
                guard enqueued else { return false }
            }
            markProcessed(entry.message, account: credentials.email, mailbox: entry.mailbox)
            try removeSkippedMessageSync(entry)
            return true
        } catch {
            approvalError = Self.draftMessage(for: error)
            logger.error("Force-draft of skipped message failed: \(error.localizedDescription)")
            return false
        }
    }

    private func hasPendingReplyWorthinessOverride(for entry: SkippedMessage, account: String) -> Bool {
        let mailbox = entry.mailbox.imapName
        let uidValidity = entry.message.uidValidity.map(String.init) ?? "?"
        let identity = "\(account)|\(mailbox)|\(uidValidity)|\(entry.message.id)"
        return pendingDrafts.contains {
            $0.identity == identity && $0.replyWorthinessOverride == true
        }
    }
}
