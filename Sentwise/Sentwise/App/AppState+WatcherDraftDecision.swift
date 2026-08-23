import SentwiseMail
import os

private let decisionLogger = Logger(subsystem: "com.tookes.Sentwise", category: "WatcherDraftDecision")

/// The outcome of building one watcher draft (item 67 gate): it was queued for
/// review, routed to the skip log because the model produced no sendable reply,
/// or dropped because the account/watch context changed mid-flight.
enum WatcherDraftResult {
    case enqueued
    case modelSkipped
    case contextChanged
}

/// Watcher draft gating that combines sender rules (item 18) with the
/// reply-worthiness check (item 17), plus the item 67 LLM relevance gate that
/// keeps model-judged automated/reply-less mail out of the review queue.
extension AppState {

    func canDraftAfterSenderRulesAndWorthiness(
        _ message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) async -> Bool {
        let skippedReason = skippedMessageReason(message, account: credentials.email, mailbox: mailbox)
        // Sender rules layer over the reply-worthiness gate: an allowlisted sender
        // is force-drafted regardless of heuristics; a blocklisted sender is
        // skipped with a visible reason. Only a no-opinion verdict falls through.
        switch senderRuleDecision(for: message) {
        case .block:
            guard skippedReason != .senderBlocklisted else { return false }
            guard watchStatus == .watching, mailCredentials == credentials else { return false }
            recordSkip(message, reason: .senderBlocklisted, account: credentials.email, mailbox: mailbox)
            return false
        case .forceDraft:
            removeSkippedMessage(message, account: credentials.email, mailbox: mailbox)
            return true
        case .noOpinion:
            if let skippedReason {
                guard skippedReason == .senderBlocklisted else { return false }
                removeSkippedMessage(message, account: credentials.email, mailbox: mailbox)
            }
            if let reason = await replyWorthinessSkipReason(message, credentials: credentials, mailbox: mailbox) {
                guard watchStatus == .watching, mailCredentials == credentials else { return false }
                recordSkip(message, reason: reason, account: credentials.email, mailbox: mailbox)
                return false
            }
            return true
        }
    }

    // MARK: - LLM relevance gate (item 67)

    /// Builds a watcher draft under the item 67 gate, retrying transient
    /// fetch/LLM hiccups within the poll (item 27). A draft with the model's
    /// explicit not-reply-worthy marker (see `isModelSkippableDraft`) is routed
    /// to the skip log (`.modelSkipped`) instead of the review queue, keeping
    /// that queue to actionable drafts. This is a *backstop*: the item 17/66
    /// heuristics run first. A genuine item-13 needs-info draft still enqueues
    /// as a flagged draft, even when its actionable request is only in the
    /// summary and it has no parsed bullet list. "Draft anyway" from the skip
    /// log re-drafts through `draftAndEnqueue`, which bypasses this gate. An
    /// allowlisted sender also bypasses the model skip so "Always draft" stays true.
    ///
    /// **Token cost:** no extra pre-classification call is made — the gate reuses
    /// the needs-info signal the single drafting call already returns, so it adds
    /// zero token cost over the pre-item-67 path (see docs/backlog resolution).
    func gatedWatcherDraftResult(
        _ message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox,
        bypassModelSkip: Bool = false
    ) async throws -> WatcherDraftResult {
        try await withResilientRetry { () -> WatcherDraftResult in
            try self.validateWatcherDraftContext(credentials)
            guard let draft = try await self.makePendingDraft(
                for: message,
                mailbox: mailbox,
                credentials: credentials
            ) else {
                return .contextChanged
            }
            if !bypassModelSkip, Self.isModelSkippableDraft(draft) {
                return .modelSkipped
            }
            try self.enqueuePendingDraft(draft)
            return .enqueued
        }
    }

    /// Applies a completed `WatcherDraftResult`: a model-skipped draft is recorded
    /// on the skip log but left unprocessed so the recovery path can reappear after
    /// restart; an enqueued draft is marked processed; a context change is left for
    /// the next poll to retry.
    func handleWatcherDraftResult(
        _ result: WatcherDraftResult,
        for message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) {
        switch result {
        case .contextChanged:
            break
        case .modelSkipped:
            recordSkip(message, reason: .notReplyWorthyPerModel, account: credentials.email, mailbox: mailbox)
        case .enqueued:
            markProcessed(message, account: credentials.email, mailbox: mailbox)
        }
    }

    /// Surfaces a watcher draft error and, for an auth failure that won't
    /// self-heal, pauses watching and records it (item 27).
    func handleWatcherDraftError(_ error: Error, draftProvider: LLMProviderKind?) {
        watchError = Self.draftMessage(for: error)
        if ResilienceClassifier.classify(error) == .authentication {
            recordActivity(ActivityEvent(
                kind: .authFailed,
                account: normalizedConnectedAccountEmail,
                detail: Self.draftMessage(for: error)
            ))
            pauseWatching(
                resumeAfterManagedReauthentication: shouldResumeAfterManagedReauthentication(
                    error: error,
                    provider: draftProvider
                )
            )
        }
        decisionLogger.error("Watcher draft failed: \(error.localizedDescription)")
    }

    func validateWatcherDraftContext(_ credentials: MailAccountCredentials) throws {
        guard watchStatus == .watching, mailCredentials == credentials else {
            throw DraftDispatchError.accountChanged
        }
    }

    /// Whether a watcher-built draft should be routed to the skip log rather
    /// than the review queue because the model explicitly produced the item 67
    /// not-reply-worthy verdict.
    ///
    /// Do not infer this from an empty needs-info bullet list. `NEEDS_INFO: Need
    /// the invoice number.` is a legitimate actionable draft whose request lives
    /// in `summary`; optional bullet formatting is not a skip signal.
    static func isModelSkippableDraft(_ draft: Draft) -> Bool {
        draft.notReplyWorthy != nil
    }
}
