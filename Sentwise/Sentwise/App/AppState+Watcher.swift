import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "InboxWatcher")

/// Inbox-watcher lifecycle and poll policy on `AppState`. The `InboxWatcher`
/// owns the timer and sleep/wake handling; this file owns *what a poll does*.
extension AppState {

    /// Whether watching can run: an account and an LLM must both be connected.
    var canWatch: Bool {
        isAccountConnected && isLLMConnected
    }

    /// Starts watching if ready — used at launch to auto-resume.
    func startWatchingIfReady() {
        guard canWatch, watchStatus != .watching else { return }
        startWatching()
    }

    /// Begins watching the inbox (schedules polling + an immediate poll).
    func startWatching() {
        guard canWatch else {
            watchError = "Connect an email account and an AI provider before watching."
            return
        }
        resumeWatchingAfterManagedReauth = false
        watchError = nil
        recordWatcherBaselineStartIfNeeded(account: mailCredentials.email, mailbox: .inbox)
        watchStatus = .watching
        if canStartInboxWatcherImmediately {
            inboxWatcher.start()
        }
        logger.info("Inbox watching started")
    }

    private var canStartInboxWatcherImmediately: Bool {
        hasConfirmedReachability || (!reachability.isStarted && reachability.hasCurrentPath)
    }

    func resumeInboxWatcherAfterReachabilityConfirmed() {
        if inboxWatcher.isActive {
            inboxWatcher.pollNow()
        } else {
            inboxWatcher.start()
        }
    }

    /// Pauses watching; the queue and processed history are kept.
    func pauseWatching(resumeAfterManagedReauthentication: Bool = false) {
        guard watchStatus == .watching else { return }
        resumeWatchingAfterManagedReauth = resumeAfterManagedReauthentication
        watchStatus = .paused
        inboxWatcher.stop()
        logger.info("Inbox watching paused")
    }

    /// Stops watching entirely (e.g. on disconnect); returns to idle.
    func stopWatching() {
        guard watchStatus != .idle else { return }
        resumeWatchingAfterManagedReauth = false
        watchStatus = .idle
        inboxWatcher.stop()
        // Outstanding auto-send countdowns (item 23) simply never fire; their
        // drafts stay pending in the queue.
        cancelAllSendCountdowns()
        logger.info("Inbox watching stopped")
    }

    /// Toggles between watching and paused for the menu-bar control.
    func toggleWatching() {
        switch watchStatus {
        case .watching:
            pauseWatching()
        case .idle, .paused:
            startWatching()
        }
    }

    /// One inbox poll: fetch recent messages, and for each new, replyable one,
    /// generate a draft and enqueue it. The first poll per account/mailbox seeds
    /// a baseline so existing mail is not drafted as newly arrived. A message is
    /// marked processed only after its draft is durably queued.
    func pollInboxOnce() async {
        guard watchStatus == .watching else { return }
        guard canWatch else {
            pauseWatching()
            return
        }
        // Offline (item 27): skip the poll rather than burn retries against an
        // unreachable server. Reconnect triggers an immediate catch-up poll.
        guard hasConfirmedReachability || !reachability.isStarted else { return }
        guard isOnline else { return }
        guard !isPollingInbox else { return }
        isPollingInbox = true
        defer { isPollingInbox = false }

        let credentials = mailCredentials
        let mailbox = Mailbox.inbox
        let messages: [MailMessage]
        do {
            messages = try await fetchWatcherMessages(
                credentials,
                mailbox: mailbox
            )
        } catch {
            handlePollFetchFailure(error)
            return
        }
        guard watchStatus == .watching, mailCredentials == credentials else { return }
        watchError = nil

        let messagesToProcess = messagesAfterSeedingWatcherBaselineIfNeeded(
            messages: messages,
            account: credentials.email,
            mailbox: mailbox
        )
        if messagesToProcess.isEmpty {
            return
        }

        // Oldest first so enqueued drafts read in chronological order.
        for message in messagesToProcess.reversed() {
            guard watchStatus == .watching, mailCredentials == credentials else { break }
            await draftMessageIfNeeded(message, credentials: credentials, mailbox: mailbox)
        }
    }

    /// Light replyability gate for the watcher: the message must have a real
    /// sender that isn't the user. Fuller filtering (newsletters, no-reply,
    /// bulk headers) is item 17.
    func isReplyable(_ message: MailMessage) -> Bool {
        guard let sender = message.from?.email, !sender.isEmpty else { return false }
        let account = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !account.isEmpty, sender.caseInsensitiveCompare(account) == .orderedSame {
            return false
        }
        return true
    }

    /// Records a message as processed and persists the updated set. Internal so
    /// the reply-worthiness gate (item 17) can mark a skipped message handled,
    /// and the override path can mark a force-drafted message handled.
    func markProcessed(_ message: MailMessage, account: String, mailbox: Mailbox) {
        processedMessages.insert(message, account: account, mailbox: mailbox)
        persistence.saveProcessedMessages(processedMessages)
    }

    private func fetchWatcherMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async throws -> [MailMessage] {
        var limit = watchFetchLimit
        var messages = try await withResilientRetry {
            try await self.mailProvider.fetchRecentMessages(
                credentials,
                mailbox: mailbox,
                limit: limit
            )
        }

        while shouldExpandWatcherFetch(
            messages: messages,
            limit: limit,
            account: credentials.email,
            mailbox: mailbox
        ) {
            let nextLimit = min(limit * 2, watchCatchUpFetchLimit)
            guard nextLimit > limit else { break }
            limit = nextLimit
            let pageLimit = limit
            messages = try await withResilientRetry {
                try await self.mailProvider.fetchRecentMessages(
                    credentials,
                    mailbox: mailbox,
                    limit: pageLimit
                )
            }
        }

        return messages
    }

    /// Handles a poll-fetch failure: transient errors just surface as `watchError`
    /// (the next poll retries), but an auth failure won't self-heal, so we pause
    /// watching and record it (item 27) rather than fail every poll.
    private func handlePollFetchFailure(_ error: Error) {
        watchError = Self.message(for: error)
        if ResilienceClassifier.classify(error) == .authentication {
            recordActivity(ActivityEvent(
                kind: .authFailed,
                account: normalizedConnectedAccountEmail,
                detail: Self.message(for: error)
            ))
            pauseWatching()
        }
        logger.error("Inbox poll fetch failed: \(error.localizedDescription)")
    }

    private func shouldExpandWatcherFetch(
        messages: [MailMessage],
        limit: Int,
        account: String,
        mailbox: Mailbox
    ) -> Bool {
        guard messages.count >= limit, limit < watchCatchUpFetchLimit else { return false }

        if let baselineUID = processedMessages.baselineUID(account: account, mailbox: mailbox),
           Self.isBaselineUIDComparable(messages: messages, baselineUID: baselineUID) {
            return !messages.contains { Self.isMessage($0, atOrBeforeBaselineUID: baselineUID) }
        }

        if let baselineStartDate = processedMessages.baselineStartDate(account: account, mailbox: mailbox) {
            return !messages.contains {
                Self.isMessage($0, beforeBaselineStart: baselineStartDate)
            }
        }

        return false
    }

    private func recordWatcherBaselineStartIfNeeded(account: String, mailbox: Mailbox, date: Date = Date()) {
        guard !processedMessages.hasBaseline(account: account, mailbox: mailbox) else { return }
        guard !processedMessages.hasBaselineStart(account: account, mailbox: mailbox) else { return }
        processedMessages.setBaselineStart(account: account, mailbox: mailbox, date: date)
        persistence.saveProcessedMessages(processedMessages)
    }

    private func draftMessageIfNeeded(
        _ message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async {
        guard isReplyable(message),
              !processedMessages.contains(message, account: credentials.email, mailbox: mailbox),
              !hasPendingDraft(for: message, account: credentials.email, mailbox: mailbox) else {
            return
        }
        guard await canDraftAfterSenderRulesAndWorthiness(message, credentials: credentials, mailbox: mailbox) else {
            return
        }
        guard watchStatus == .watching, mailCredentials == credentials else { return }
        let draftProvider = currentDraftLLMConfiguration?.provider

        do {
            // Retry transient fetch/LLM hiccups within the poll (item 27). On
            // exhaustion the message is left unprocessed, so the next poll retries
            // it — the existing skip/pending-draft guards prevent re-notification.
            let result = try await gatedWatcherDraftResult(message, credentials: credentials, mailbox: mailbox)
            guard watchStatus == .watching, mailCredentials == credentials else { return }
            handleWatcherDraftResult(result, for: message, credentials: credentials, mailbox: mailbox)
        } catch {
            handleWatcherDraftError(error, draftProvider: draftProvider)
        }
    }

    private func messagesAfterSeedingWatcherBaselineIfNeeded(
        messages: [MailMessage],
        account: String,
        mailbox: Mailbox
    ) -> [MailMessage] {
        let hasBaseline = processedMessages.hasBaseline(account: account, mailbox: mailbox)
        let baselineStartDate = processedMessages.baselineStartDate(account: account, mailbox: mailbox)
        let baselineUID = processedMessages.baselineUID(account: account, mailbox: mailbox)

        if hasBaseline {
            return messages.filter {
                Self.isMessage(
                    $0,
                    afterBaselineUID: baselineUID,
                    onOrAfterBaselineStart: baselineStartDate
                )
            }
        }

        let messagesToProcess: [MailMessage]
        let baselineMessages: [MailMessage]
        if let baselineUID {
            messagesToProcess = messages.filter { Self.isMessage($0, afterBaselineUID: baselineUID) }
            baselineMessages = messages.filter { Self.isMessage($0, atOrBeforeBaselineUID: baselineUID) }
        } else if let baselineStartDate {
            messagesToProcess = messages.filter {
                Self.isMessage($0, onOrAfterInitialBaselineStart: baselineStartDate)
            }
            baselineMessages = messages.filter {
                !Self.isMessage($0, onOrAfterInitialBaselineStart: baselineStartDate)
            }
        } else {
            messagesToProcess = []
            baselineMessages = messages
        }

        if baselineUID == nil, let historicalCutoff = baselineMessages.max(by: { $0.id < $1.id }) {
            processedMessages.setBaselineUID(
                account: account,
                mailbox: mailbox,
                uid: historicalCutoff.id,
                uidValidity: historicalCutoff.uidValidity
            )
        }

        for message in baselineMessages {
            processedMessages.insert(message, account: account, mailbox: mailbox)
        }
        processedMessages.insertBaseline(account: account, mailbox: mailbox)
        persistence.saveProcessedMessages(processedMessages)
        logger.info("Inbox watcher baseline seeded: \(baselineMessages.count) historical, \(messagesToProcess.count) post-start eligible")
        return baselineStartDate == nil ? [] : messagesToProcess
    }

    private func hasPendingDraft(for message: MailMessage, account: String, mailbox: Mailbox) -> Bool {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mailbox = mailbox.imapName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return pendingDrafts.contains { draft in
            guard draft.sourceAccountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == account,
                  draft.sourceMailbox?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == mailbox else {
                return false
            }
            let matchesMessageID = draft.sourceMessageID.map { sourceMessageID in
                guard let messageID = message.messageID else { return false }
                return !sourceMessageID.isEmpty && sourceMessageID == messageID
            } ?? false
            let matchesUID = draft.sourceUIDValidity == message.uidValidity && draft.id == message.id
            return matchesMessageID || matchesUID
        }
    }

    private static func isMessage(
        _ message: MailMessage,
        afterBaselineUID baselineUID: ProcessedMessages.BaselineUIDCutoff?,
        onOrAfterBaselineStart startDate: Date?
    ) -> Bool {
        guard let baselineUID else {
            return isMessage(message, onOrAfterBaselineStart: startDate)
        }
        guard isMessageUIDComparable(message, baselineUID: baselineUID) else {
            return isMessage(message, onOrAfterBaselineStart: startDate)
        }
        return isMessage(message, afterBaselineUID: baselineUID)
    }

    private static func isBaselineUIDComparable(
        messages: [MailMessage],
        baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard let baselineUIDValidity = baselineUID.uidValidity else { return true }
        return !messages.contains {
            guard let messageUIDValidity = $0.uidValidity else { return false }
            return messageUIDValidity != baselineUIDValidity
        }
    }

    private static func isMessage(
        _ message: MailMessage,
        afterBaselineUID baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard isMessageUIDComparable(message, baselineUID: baselineUID) else { return true }
        return message.id > baselineUID.uid
    }

    private static func isMessage(
        _ message: MailMessage,
        atOrBeforeBaselineUID baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard isMessageUIDComparable(message, baselineUID: baselineUID) else { return false }
        return message.id <= baselineUID.uid
    }

    private static func isMessageUIDComparable(
        _ message: MailMessage,
        baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard let baselineUIDValidity = baselineUID.uidValidity,
              let messageUIDValidity = message.uidValidity else {
            return true
        }
        return messageUIDValidity == baselineUIDValidity
    }

    private static func isMessage(_ message: MailMessage, onOrAfterBaselineStart startDate: Date?) -> Bool {
        guard let startDate else { return true }
        if let date = parsedMessageDate(message.date) {
            return date >= startDate
        }
        return true
    }

    private static func isMessage(_ message: MailMessage, onOrAfterInitialBaselineStart startDate: Date) -> Bool {
        guard let date = parsedMessageDate(message.date) else { return false }
        return date >= startDate
    }

    private static func isMessage(_ message: MailMessage, beforeBaselineStart startDate: Date) -> Bool {
        guard let date = parsedMessageDate(message.date) else { return false }
        return date < startDate
    }

    static func parsedMessageDate(_ value: String) -> Date? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for candidate in rfc5322DateCandidates(value) {
            for format in [
                "EEE, d MMM yyyy HH:mm:ss Z",
                "d MMM yyyy HH:mm:ss Z",
                "EEE, d MMM yyyy HH:mm Z",
                "d MMM yyyy HH:mm Z"
            ] {
                formatter.dateFormat = format
                if let date = formatter.date(from: candidate) {
                    return date
                }
            }
        }
        return nil
    }

    private static func rfc5322DateCandidates(_ value: String) -> [String] {
        let withoutComments = strippedRFC5322Comments(from: value)
        guard withoutComments != value else { return [value] }
        return [value, withoutComments]
    }

    private static func strippedRFC5322Comments(from value: String) -> String {
        var output = ""
        var commentDepth = 0
        var isEscapingCommentCharacter = false

        for character in value {
            if commentDepth > 0 {
                if isEscapingCommentCharacter {
                    isEscapingCommentCharacter = false
                } else if character == "\\" {
                    isEscapingCommentCharacter = true
                } else if character == "(" {
                    commentDepth += 1
                } else if character == ")" {
                    commentDepth -= 1
                }
                continue
            }

            if character == "(" {
                commentDepth = 1
            } else {
                output.append(character)
            }
        }

        return output
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
