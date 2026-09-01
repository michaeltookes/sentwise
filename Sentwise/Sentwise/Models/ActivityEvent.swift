import SentwiseMail
import Foundation

/// A single entry in the user-facing activity history (item 21): a durable record
/// of something the assistant did — a draft created, an approval sent or saved, a
/// denial, a reply-worthiness skip, a stale-thread warning, or a send failure.
///
/// **Privacy:** this stores metadata only — sender, subject, and a reason — never
/// message bodies or draft content, consistent with the local-first ethos. The
/// optional `messageUID` + `messageUIDValidity` + source server let the history
/// link back to the source message when the account/mailbox still match the
/// connected account.
enum ActivitySubjectSource: String, Codable, Equatable {
    case incomingHeader
    case authored
}

struct ActivityEvent: Codable, Identifiable, Equatable {
    /// Stable identity for list rendering (not derived from message keys, so two
    /// events about the same message remain distinct history entries).
    var id: UUID
    /// When the event happened.
    var timestamp: Date
    /// What happened.
    var kind: ActivityEventKind
    /// The account the event relates to (normalized email), when known.
    var account: String?
    /// The source mailbox's stable `imapName`, when known.
    var mailbox: String?
    /// The source IMAP host that issued the message UID/UIDVALIDITY, when known.
    var sourceMailHost: String?
    /// The source IMAP port that issued the message UID/UIDVALIDITY, when known.
    var sourceMailPort: Int?
    /// The other party's display name or address, for the row headline.
    var sender: String?
    /// The message subject, for the row.
    var subject: String?
    /// Where `subject` came from, so authored follow-up subjects are displayed
    /// exactly as typed while inbound headers can be RFC 2047-decoded for display.
    var subjectSource: ActivitySubjectSource?
    /// Why a message was skipped (item 17), for `.skipped` events.
    var skipReason: ReplyWorthinessReason?
    /// Why an approval was blocked (item 12), for `.staleWarning` events.
    var staleReason: StaleThreadReason?
    /// A short free-form detail (e.g. a send-failure message). Never a body/draft.
    var detail: String?
    /// The source message's IMAP UID, for linking back to it.
    var messageUID: UInt32?
    /// UIDVALIDITY captured with the UID, so linkage is only offered when safe.
    var messageUIDValidity: UInt32?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: ActivityEventKind,
        account: String? = nil,
        mailbox: String? = nil,
        sourceMailHost: String? = nil,
        sourceMailPort: Int? = nil,
        sender: String? = nil,
        subject: String? = nil,
        subjectSource: ActivitySubjectSource? = nil,
        skipReason: ReplyWorthinessReason? = nil,
        staleReason: StaleThreadReason? = nil,
        detail: String? = nil,
        messageUID: UInt32? = nil,
        messageUIDValidity: UInt32? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.account = account
        self.mailbox = mailbox
        self.sourceMailHost = sourceMailHost
        self.sourceMailPort = sourceMailPort
        self.sender = sender
        self.subject = subject
        self.subjectSource = subjectSource
        self.skipReason = skipReason
        self.staleReason = staleReason
        self.detail = detail
        self.messageUID = messageUID
        self.messageUIDValidity = messageUIDValidity
    }

    /// The reason headline to show under the event kind, when the event carries a
    /// typed reason (skip or stale). Reuses the existing reason copy so item 17's
    /// deferred "skip reasons visible in the activity log" criterion is satisfied.
    var reasonHeadline: String? {
        skipReason?.headline ?? staleReason?.headline
    }

    /// The longer reason explanation, when available.
    var reasonDetail: String? {
        skipReason?.detail ?? staleReason?.detail ?? detail
    }

    /// The sender/subject line for the row, with sensible fallbacks.
    var senderDisplay: String { sender ?? "Unknown sender" }

    /// The subject for the row, with an empty-subject fallback.
    var subjectDisplay: String {
        let rawSubject = subject ?? ""
        guard !rawSubject.isEmpty else { return "(no subject)" }
        return subjectSource == .authored ? rawSubject : MIMEEncodedWord.displaySubject(rawSubject)
    }

    /// The free-form detail currently rendered in the activity-history row.
    var activityHistoryVisibleDetail: String? {
        guard let detail else { return nil }
        if kind == .denied {
            return Self.visibleDenyReasonDetail(from: detail)
        }
        return kind.showsFailureDetail || kind.showsSuccessDetail ? detail : nil
    }

    /// The explicit accessibility label installed by the activity-history row.
    var activityHistoryAccessibilityLabel: String {
        var parts = [kind.headline]
        if let reason = reasonHeadline { parts.append(reason) }
        parts.append(senderDisplay)
        parts.append(subjectDisplay)
        if let detail = activityHistoryVisibleDetail { parts.append(detail) }
        parts.append(timestamp.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: ", ")
    }

    private static func visibleDenyReasonDetail(from rawCode: String) -> String? {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        let title = DenyReasonCode(rawValue: code)?.displayTitle ?? code
        return "Reason: \(title)"
    }
}

/// The kinds of activity the assistant records. These map one-to-one to streams
/// the app already has — no speculative kinds.
enum ActivityEventKind: String, Codable, Equatable, CaseIterable {
    /// A reply draft was created (watcher, force-draft override, or manual preview).
    case draftCreated
    /// An approved draft was sent immediately (auto-send).
    case approvedSent
    /// An approved draft was saved to the Drafts mailbox.
    case approvedSaved
    /// A pending draft was denied / discarded.
    case denied
    /// A message was skipped by the reply-worthiness gate (item 17).
    case skipped
    /// A stale-thread warning was raised at approval time (item 12).
    case staleWarning
    /// An auto-send was canceled during its safety-net window (item 23).
    case sendCanceled
    /// Sending an approved draft failed.
    case sendFailed
    /// Saving an approved draft to the Drafts mailbox failed (IMAP APPEND).
    case saveFailed
    /// An approved draft's dispatch was deferred because the network is offline
    /// (item 27). It stays pending and dispatches automatically on reconnect.
    case queuedOffline
    /// The network came back and queued work resumed (item 27).
    case resumedOnline
    /// A resilient operation exhausted its transient-retry budget and gave up
    /// while online (item 27).
    case retryExhausted
    /// A mail or LLM authentication failure that won't be retried and needs the
    /// user to re-enter their credentials (item 27).
    case authFailed
    /// A Google Workspace / Gmail policy blocked the IMAP sign-in and targeted
    /// guidance was shown (item 75). `detail` carries the PII-free failure class
    /// name only (never the email, server text, or credential) so the maintainer
    /// can see how often launch users hit this while dogfooding.
    case workspaceAuthGuidance

    /// A short label for the event row.
    var headline: String {
        switch self {
        case .draftCreated: return "Draft created"
        case .approvedSent: return "Sent"
        case .approvedSaved: return "Saved to Drafts"
        case .denied: return "Denied"
        case .skipped: return "Skipped"
        case .staleWarning: return "Stale-thread warning"
        case .sendCanceled: return "Send canceled"
        case .sendFailed: return "Send failed"
        case .saveFailed: return "Save failed"
        case .queuedOffline: return "Waiting for network"
        case .resumedOnline: return "Back online"
        case .retryExhausted: return "Gave up after retries"
        case .authFailed: return "Sign-in failed"
        case .workspaceAuthGuidance: return "Workspace sign-in blocked"
        }
    }

    /// An SF Symbol name for the event row.
    var systemImage: String {
        switch self {
        case .draftCreated: return "square.and.pencil"
        case .approvedSent: return "paperplane"
        case .approvedSaved: return "tray.and.arrow.down"
        case .denied: return "xmark.circle"
        case .skipped: return "nosign"
        case .staleWarning: return "exclamationmark.triangle"
        case .sendCanceled: return "arrow.uturn.backward.circle"
        case .sendFailed: return "exclamationmark.octagon"
        case .saveFailed: return "exclamationmark.octagon"
        case .queuedOffline: return "wifi.slash"
        case .resumedOnline: return "wifi"
        case .retryExhausted: return "arrow.clockwise.circle"
        case .authFailed: return "person.crop.circle.badge.exclamationmark"
        case .workspaceAuthGuidance: return "building.2.crop.circle.badge.exclamationmark"
        }
    }

    /// Whether rows should render the free-form failure diagnostic.
    var showsFailureDetail: Bool {
        switch self {
        case .sendFailed, .saveFailed, .retryExhausted, .authFailed, .workspaceAuthGuidance: return true
        default: return false
        }
    }

    /// Whether rows should render a non-error detail such as an edit note.
    var showsSuccessDetail: Bool {
        switch self {
        case .approvedSent, .approvedSaved, .denied: return true
        default: return false
        }
    }
}
