import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "ActivityHistory")

/// Activity-history recording and linkage on `AppState` (item 21). The history is
/// a bounded, persisted log of what the assistant did — drafts created, approvals
/// sent/saved, denials, reply-worthiness skips, stale-thread warnings, and send
/// failures. It stores **metadata only** (sender/subject/reason), never message
/// bodies or draft content, and links back to a source message when the
/// account/mailbox still match the connected account.
extension AppState {

    /// Maximum number of activity-history entries kept; oldest dropped past this.
    var activityEventLogLimit: Int { 500 }

    // MARK: - Recording

    /// Records `event` at the front of the history (newest first), evicting the
    /// oldest entries past `activityEventLogLimit`, and persists the result.
    func recordActivity(_ event: ActivityEvent) {
        activityEvents.insert(event, at: 0)
        if activityEvents.count > activityEventLogLimit {
            activityEvents.removeLast(activityEvents.count - activityEventLogLimit)
        }
        persistence.saveActivityEvents(activityEvents)
        logger.info("Recorded activity event (\(event.kind.rawValue, privacy: .public))")
    }

    /// Records a draft-scoped event (created / sent / saved / denied / stale /
    /// send-failed) from a `Draft`, capturing linkage metadata from its source.
    func recordDraftActivity(
        _ kind: ActivityEventKind,
        for draft: Draft,
        staleReason: StaleThreadReason? = nil,
        detail: String? = nil
    ) {
        recordActivity(ActivityEvent(
            kind: kind,
            account: draft.sourceAccountEmail,
            mailbox: draft.sourceMailbox,
            sourceMailHost: Self.normalizedActivitySourceMailHost(draft.sourceMailHost),
            sourceMailPort: Self.normalizedActivitySourceMailPort(draft.sourceMailPort),
            sender: draft.sourceFrom?.name ?? draft.sourceFrom?.email,
            subject: draft.sourceSubject,
            subjectSource: draft.isAuthored ? .authored : .incomingHeader,
            staleReason: staleReason,
            detail: detail,
            messageUID: draft.id,
            messageUIDValidity: draft.sourceUIDValidity
        ))
    }

    /// Records a durable skip event from a `SkippedMessage` (item 17). The
    /// in-memory `skippedMessages` override entry still carries the full message
    /// for "Draft anyway"; this metadata-only event survives restart.
    func recordSkipActivity(for entry: SkippedMessage) {
        recordSkipActivity(
            for: entry,
            sourceMailHost: currentActivitySourceMailHost,
            sourceMailPort: currentActivitySourceMailPort
        )
    }

    func recordSkipActivity(for entry: SkippedMessage, sourceMailHost: String?, sourceMailPort: Int?) {
        let event = ActivityEvent(
            kind: .skipped,
            account: entry.account,
            mailbox: entry.mailbox.imapName,
            sourceMailHost: Self.normalizedActivitySourceMailHost(sourceMailHost),
            sourceMailPort: Self.normalizedActivitySourceMailPort(sourceMailPort),
            sender: entry.senderDisplay,
            subject: entry.subject,
            skipReason: entry.reason,
            messageUID: entry.message.id,
            messageUIDValidity: entry.message.uidValidity
        )
        if refreshExistingSkipActivity(matching: event) {
            return
        }
        recordActivity(event)
    }

    /// Clears the entire activity history and persists the empty log.
    func clearActivityHistory() {
        activityEvents.removeAll()
        persistence.saveActivityEvents(activityEvents)
    }

    // MARK: - Link back to the source message

    /// Whether the history entry can open its source message: it carries a UID
    /// with UIDVALIDITY, and the still-connected account/server matches the one
    /// the event was recorded under.
    /// Mailbox naming is provider-specific, so linkage reuses the existing
    /// fetch/preview path rather than building new IMAP machinery.
    func canOpenActivityEvent(_ event: ActivityEvent) -> Bool {
        guard event.messageUID != nil,
              event.messageUIDValidity != nil,
              isAccountConnected,
              let account = event.account,
              let eventMailHost = Self.normalizedActivitySourceMailHost(event.sourceMailHost),
              let eventMailPort = Self.normalizedActivitySourceMailPort(event.sourceMailPort),
              let connectedMailHost = currentActivitySourceMailHost,
              let connectedMailPort = currentActivitySourceMailPort else {
            return false
        }
        let connected = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return account.caseInsensitiveCompare(connected) == .orderedSame
            && eventMailHost == connectedMailHost
            && eventMailPort == connectedMailPort
    }

    /// Opens the source message's readable-body preview for a history entry, when
    /// linkage is possible. Returns the fetched preview so the caller can present
    /// it in its own sheet. Returns `nil` when linkage isn't available, the
    /// account changes during the fetch, or the fetch fails.
    @discardableResult
    func openActivityEvent(_ event: ActivityEvent) async -> MailBodyPreview? {
        guard canOpenActivityEvent(event),
              let uid = event.messageUID,
              let uidValidity = event.messageUIDValidity else { return nil }
        let credentials = mailCredentials
        guard credentials.isComplete else { return nil }
        let message = MailMessage(
            id: uid,
            uidValidity: uidValidity,
            from: nil,
            subject: event.subject ?? "",
            date: ""
        )
        let mailbox = event.mailbox.map(Self.mailbox(forStableName:)) ?? .inbox
        do {
            let preview = try await fetchBodyPreview(for: message, mailbox: mailbox, credentials: credentials)
            guard mailCredentials == credentials else { return nil }
            return preview
        } catch {
            logger.error("Failed to open activity source message: \(error.localizedDescription)")
            return nil
        }
    }

    /// Maps a persisted stable `imapName` back to a `Mailbox` case so linkage
    /// re-fetches through the same provider-aware naming resolution used elsewhere.
    static func mailbox(forStableName name: String) -> Mailbox {
        switch name {
        case Mailbox.inbox.imapName: return .inbox
        case Mailbox.sent.imapName: return .sent
        case Mailbox.drafts.imapName: return .drafts
        case Mailbox.allMail.imapName: return .allMail
        case Mailbox.trash.imapName: return .trash
        default: return .named(name)
        }
    }

    private var currentActivitySourceMailHost: String? {
        Self.normalizedActivitySourceMailHost(mailHost)
    }

    private var currentActivitySourceMailPort: Int? {
        Self.normalizedActivitySourceMailPort(mailPort)
    }

    private static func normalizedActivitySourceMailHost(_ host: String?) -> String? {
        let normalized = (host ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedActivitySourceMailPort(_ port: Int?) -> Int? {
        guard let port, port > 0 else { return nil }
        return port
    }

    private func refreshExistingSkipActivity(matching event: ActivityEvent) -> Bool {
        guard let index = activityEvents.firstIndex(where: { Self.isSameSkipActivity($0, event) }) else {
            return false
        }

        var refreshed = activityEvents.remove(at: index)
        refreshed.timestamp = event.timestamp
        refreshed.account = event.account
        refreshed.mailbox = event.mailbox
        refreshed.sourceMailHost = event.sourceMailHost
        refreshed.sourceMailPort = event.sourceMailPort
        refreshed.sender = event.sender
        refreshed.subject = event.subject
        refreshed.skipReason = event.skipReason
        refreshed.messageUID = event.messageUID
        refreshed.messageUIDValidity = event.messageUIDValidity
        activityEvents.insert(refreshed, at: 0)
        persistence.saveActivityEvents(activityEvents)
        logger.info("Refreshed skipped activity event")
        return true
    }

    private static func isSameSkipActivity(_ existing: ActivityEvent, _ event: ActivityEvent) -> Bool {
        guard existing.kind == .skipped,
              event.kind == .skipped,
              existing.account?.caseInsensitiveCompare(event.account ?? "") == .orderedSame,
              existing.mailbox == event.mailbox,
              existing.messageUID == event.messageUID,
              existing.messageUIDValidity == event.messageUIDValidity else {
            return false
        }

        let existingHost = normalizedActivitySourceMailHost(existing.sourceMailHost)
        let eventHost = normalizedActivitySourceMailHost(event.sourceMailHost)
        if let existingHost, let eventHost, existingHost != eventHost {
            return false
        }

        let existingPort = normalizedActivitySourceMailPort(existing.sourceMailPort)
        let eventPort = normalizedActivitySourceMailPort(event.sourceMailPort)
        if let existingPort, let eventPort, existingPort != eventPort {
            return false
        }

        return true
    }
}
