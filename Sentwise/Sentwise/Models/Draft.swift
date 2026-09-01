import SentwiseMail
import Foundation

/// Why the assistant couldn't confidently draft a reply — the reply would need
/// information only the user has (item 13). Attached to a `Draft` so the flagged
/// state persists through the pending queue and survives relaunch.
struct DraftNeedsInfo: Codable, Equatable {
    /// One-line explanation of why a confident reply isn't possible.
    var summary: String
    /// Specific things the user would need to supply to complete the reply.
    var missing: [String]

    init(summary: String, missing: [String] = []) {
        self.summary = summary
        self.missing = missing
    }
}

/// The assistant explicitly judged that the source message does not call for a
/// reply. This is distinct from `DraftNeedsInfo`: there is no actionable user
/// fact to supply, so the watcher may route it to the skip log.
struct DraftNotReplyWorthy: Codable, Equatable {
    /// One-line explanation of why a written reply is not useful.
    var summary: String
}

/// Original skip-log identity for a user-requested "Draft anyway" override.
/// Regenerated drafts may reply to a newer thread message, so this preserves the
/// recovery entry they came from for retry/deduplication.
struct DraftReplyWorthinessOverrideSource: Codable, Equatable {
    var account: String
    var mailbox: String
    var id: UInt32
    var uidValidity: UInt32?
    var messageID: String?

    init(account: String, mailbox: String, id: UInt32, uidValidity: UInt32?, messageID: String?) {
        self.account = account
        self.mailbox = mailbox
        self.id = id
        self.uidValidity = uidValidity
        self.messageID = messageID
    }

    init(account: String, mailbox: Mailbox, message: MailMessage) {
        self.init(
            account: account,
            mailbox: mailbox.imapName,
            id: message.id,
            uidValidity: message.uidValidity,
            messageID: message.messageID
        )
    }
}

/// A user's already-approved dispatch. Stored on the pending draft so offline
/// approvals survive relaunch with the exact approval mode the user chose.
struct OfflineQueuedDraftDispatch: Codable, Equatable {
    var sendBehavior: SendBehavior
    var force: Bool
    var isDispatchInFlight: Bool

    init(sendBehavior: SendBehavior, force: Bool = false, isDispatchInFlight: Bool = false) {
        self.sendBehavior = sendBehavior
        self.force = force
        self.isDispatchInFlight = isDispatchInFlight
    }

    private enum CodingKeys: String, CodingKey {
        case sendBehavior
        case force
        case isDispatchInFlight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawBehavior = try container.decodeIfPresent(String.self, forKey: .sendBehavior)
        sendBehavior = rawBehavior.flatMap(SendBehavior.init(rawValue:)) ?? .default
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
        isDispatchInFlight = try container.decodeIfPresent(Bool.self, forKey: .isDispatchInFlight) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sendBehavior.rawValue, forKey: .sendBehavior)
        try container.encode(force, forKey: .force)
        try container.encode(isDispatchInFlight, forKey: .isDispatchInFlight)
    }
}

/// A generated reply draft, associated with the message it replies to so it can
/// be threaded and sent correctly later (items 9 & 12).
struct Draft: Codable, Identifiable, Equatable {
    /// The source message's IMAP UID (stable within its mailbox).
    var id: UInt32
    /// UIDVALIDITY captured with the source UID, for safe re-fetch before send.
    var sourceUIDValidity: UInt32?
    /// The account that produced this draft.
    var sourceAccountEmail: String?
    /// The IMAP host that issued the source UID/UIDVALIDITY.
    var sourceMailHost: String?
    /// The IMAP port that issued the source UID/UIDVALIDITY.
    var sourceMailPort: Int?
    /// The mailbox that contained the source message.
    var sourceMailbox: String?
    /// The source message's subject.
    var sourceSubject: String
    /// The source message's sender.
    var sourceFrom: MailAddress?
    /// The address replies should be sent to, when the source specified one.
    var sourceReplyTo: MailAddress?
    /// The source message's RFC 5322 `Message-ID`, for reply threading.
    var sourceMessageID: String?
    /// The readable text of the incoming message, kept so the approval UI can
    /// show it beside the proposed reply. Truncated to bound persistence size.
    var incomingBody: String?
    /// The reply subject (`Re: …`).
    var replySubject: String
    /// The generated reply body. Empty when the draft is flagged as needing the
    /// user's input (`needsInfo` set) — there is no fabricated reply to send.
    /// When the user edits the draft before approving (item 19), this holds the
    /// edited text — it is what actually gets sent or saved.
    var body: String
    /// The assistant's originally generated body, captured the first time the
    /// user edits `body` (item 19). Retained so a later voice-tuning step
    /// (items 20/34) can compare what was generated against what the user sent.
    /// `nil` when the draft has never been edited.
    var originalBody: String?
    /// The model that produced the draft.
    var model: String
    /// When the draft was generated.
    var generatedAt: Date
    /// When the user explicitly regenerated this draft. `generatedAt` stays tied to
    /// the original draft for stale-thread search windows.
    var regeneratedAt: Date?
    /// Set when the assistant declined to fabricate a reply because it needs
    /// information only the user has (item 13). A flagged draft is never sent or
    /// saved until the user resolves it.
    var needsInfo: DraftNeedsInfo?
    /// Set only when the model used the dedicated not-reply-worthy protocol.
    /// Watcher code uses this explicit marker to skip automated/reply-less mail.
    var notReplyWorthy: DraftNotReplyWorthy?
    /// Whether this draft came from the skip log's user-requested "Draft
    /// anyway" override. Optional so existing persisted drafts decode cleanly;
    /// `nil` means an old draft has no migration-safe provenance.
    var replyWorthinessOverride: Bool?
    /// The skipped message identity that produced a "Draft anyway" override.
    var replyWorthinessOverrideSource: DraftReplyWorthinessOverrideSource?
    /// Whether this reply draft came from an explicit user-requested preview
    /// rather than the watcher. Optional so existing persisted drafts decode
    /// cleanly; `nil` means an old draft has no migration-safe preview provenance.
    var manualPreview: Bool?
    /// An approved dispatch that could not run because the network was offline.
    /// Once dispatch starts, the intent is marked terminal so relaunch cannot
    /// automatically repeat a send whose post-send persistence failed.
    var offlineQueuedDispatch: OfflineQueuedDraftDispatch?

    /// Facts the user typed to answer a `NEEDS_INFO` draft (item 85). Carried on
    /// the draft so they persist through the pending queue and a relaunch, and are
    /// re-injected into the generator prompt on every re-draft. `nil` until the
    /// user answers. Local-only: never logged or written to the activity history.
    var userSuppliedFacts: UserSuppliedFacts?

    /// How many times an answered re-draft still came back `NEEDS_INFO` (item 85).
    /// Drives the escape hatch: after the second failed round the card offers
    /// "write it yourself". `nil`/`0` for a draft the user hasn't re-drafted with
    /// answers, or one whose re-draft produced a usable reply.
    var answeredRedraftCount: Int?

    /// User-supplied recipients for an authored follow-up that has no inbound
    /// source message (item 51). When non-`nil` this draft is an *authored*
    /// follow-up rather than a reply: dispatch sends to these addresses and does
    /// not thread (no `In-Reply-To`/`References`), and `replySubject` is used
    /// verbatim rather than as a `Re:` reply. `nil` for reply drafts, which derive
    /// their recipient from the source message. An empty array means the follow-up
    /// is authored but still needs recipients before it can be sent (the
    /// watched-folder path enqueues drafts this way for the user to complete).
    var authoredRecipients: [MailAddress]?

    /// Legacy parsed transcript context for authored post-call follow-ups. New
    /// drafts use `followUpContext`; this remains so already-queued drafts from
    /// earlier builds can still be re-drafted with the original call context.
    var followUpTranscript: ParsedTranscript?

    /// Bounded transcript-or-summary context used to regenerate authored
    /// follow-ups without persisting unbounded pasted or watched transcripts.
    var followUpContext: FollowUpDraftContext?

    /// Whether this draft currently needs user input before approval. A model
    /// `NOT_REPLY_WORTHY` override becomes dispatchable only after the user writes
    /// a non-empty reply body.
    var isFlagged: Bool {
        needsInfo != nil
            || (notReplyWorthy != nil && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Whether this is an authored follow-up (item 51) rather than a reply to an
    /// incoming message. Authored drafts have no source thread, so freshness and
    /// regeneration checks don't apply and recipients come from the user.
    var isAuthored: Bool { authoredRecipients != nil }

    /// Whether an authored follow-up has at least one recipient to dispatch to.
    var hasAuthoredRecipients: Bool { !(authoredRecipients ?? []).isEmpty }

    /// Whether the user edited the reply body away from what the assistant
    /// generated (item 19). True only when an original was captured and the
    /// current body still differs from it.
    var wasEdited: Bool {
        guard let originalBody else { return false }
        return originalBody != body
    }

    /// Whether the user answered a `NEEDS_INFO` prompt on this draft (item 85):
    /// the draft carries at least one non-blank supplied fact. Item 83's
    /// approval-signal capture consumes this to record an "answered-then-approved"
    /// outcome once that capture exists.
    var wasAnswered: Bool {
        guard let userSuppliedFacts else { return false }
        return !userSuppliedFacts.isEmpty
    }

    /// How many answered re-drafts still returned `NEEDS_INFO` (item 85).
    var answeredRedraftFailures: Int { answeredRedraftCount ?? 0 }

    /// The approval-signal provenance of this draft (item 83, Phase 1): authored
    /// follow-up, user-forced "Draft anyway" skip-log override, manual preview,
    /// or watcher draft.
    ///
    /// **Seam (item 68):** `watcher` is a single bucket today. Item 68's
    /// header-fetch-degradation diagnosis may later refine it (a draft that
    /// slipped past a *degraded* reply-worthiness check vs. a clean one);
    /// `DraftFeedbackProvenance` is where that split would land.
    var feedbackProvenance: DraftFeedbackProvenance {
        if isAuthored { return .authored }
        if replyWorthinessOverride == true { return .draftAnyway }
        if manualPreview == true { return .manualPreview }
        return .watcher
    }

    /// Whether the card should surface the "write it yourself" escape: the user
    /// has answered and re-drafted at least twice and the model still needs input.
    var shouldOfferWriteItYourself: Bool {
        needsInfo != nil && answeredRedraftFailures >= 2
    }

    /// Applies a user edit to the reply body (item 19), capturing the assistant's
    /// original body the first time it diverges so a later voice-tuning step can
    /// learn from the difference. A no-op when the text is unchanged, so `body`
    /// stays the edited text and `identity` is unaffected (identity excludes the
    /// body — see `identity`).
    mutating func applyEditedBody(_ newBody: String) {
        guard newBody != body else { return }
        if originalBody == nil {
            originalBody = body
        }
        body = newBody
    }

    init(
        id: UInt32,
        sourceUIDValidity: UInt32?,
        sourceAccountEmail: String? = nil,
        sourceMailHost: String? = nil,
        sourceMailPort: Int? = nil,
        sourceMailbox: String? = nil,
        sourceSubject: String,
        sourceFrom: MailAddress?,
        sourceReplyTo: MailAddress?,
        sourceMessageID: String?,
        incomingBody: String? = nil,
        replySubject: String,
        body: String,
        originalBody: String? = nil,
        model: String,
        generatedAt: Date,
        regeneratedAt: Date? = nil,
        needsInfo: DraftNeedsInfo? = nil,
        notReplyWorthy: DraftNotReplyWorthy? = nil,
        offlineQueuedDispatch: OfflineQueuedDraftDispatch? = nil,
        authoredRecipients: [MailAddress]? = nil,
        followUpTranscript: ParsedTranscript? = nil,
        followUpContext: FollowUpDraftContext? = nil,
        replyWorthinessOverride: Bool = false,
        replyWorthinessOverrideSource: DraftReplyWorthinessOverrideSource? = nil,
        manualPreview: Bool = false,
        userSuppliedFacts: UserSuppliedFacts? = nil,
        answeredRedraftCount: Int? = nil
    ) {
        self.id = id
        self.sourceUIDValidity = sourceUIDValidity
        self.sourceAccountEmail = sourceAccountEmail
        self.sourceMailHost = sourceMailHost
        self.sourceMailPort = sourceMailPort
        self.sourceMailbox = sourceMailbox
        self.sourceSubject = sourceSubject
        self.sourceFrom = sourceFrom
        self.sourceReplyTo = sourceReplyTo
        self.sourceMessageID = sourceMessageID
        self.incomingBody = incomingBody
        self.replySubject = replySubject
        self.body = body
        self.originalBody = originalBody
        self.model = model
        self.generatedAt = generatedAt
        self.regeneratedAt = regeneratedAt
        self.needsInfo = needsInfo
        self.notReplyWorthy = notReplyWorthy
        self.replyWorthinessOverride = replyWorthinessOverride
        self.replyWorthinessOverrideSource = replyWorthinessOverrideSource
        self.manualPreview = manualPreview
        self.offlineQueuedDispatch = offlineQueuedDispatch
        self.authoredRecipients = authoredRecipients
        self.followUpTranscript = followUpTranscript
        self.followUpContext = followUpContext
        self.userSuppliedFacts = userSuppliedFacts
        self.answeredRedraftCount = answeredRedraftCount
    }

    /// A stable identity across the pending queue and notifications, scoped by
    /// account/mailbox so the same UID in different mailboxes never collides.
    /// Deliberately excludes `body`, so editing the reply (item 19) keeps the
    /// draft's approval/stale-warning bookkeeping keys stable.
    var identity: String {
        let account = sourceAccountEmail ?? "?"
        let mailbox = sourceMailbox ?? "?"
        let validity = sourceUIDValidity.map(String.init) ?? "?"
        return "\(account)|\(mailbox)|\(validity)|\(id)"
    }
}
