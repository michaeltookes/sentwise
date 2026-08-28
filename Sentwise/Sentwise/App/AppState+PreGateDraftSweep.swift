import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "PreGateDraftSweep")

private let preGateDraftSweepCutoff: Date = {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 8
    components.day = 23
    return components.date ?? .distantPast
}()

private struct PreGateDraftSweepResult {
    var sweptCount: Int
    var completed: Bool
}

/// One-time reply-worthiness sweep of pre-gate pending drafts (item 80).
///
/// The transactional / no-reply reply-worthiness gate (items 66/67) only runs at
/// draft-*creation* time. Drafts enqueued before that gate merged (2026-08-23)
/// are never re-evaluated, so a Review Drafts queue can carry pre-fix junk —
/// order/shipment/receipt mail from `auto-confirm@amazon.com`,
/// `shipment-tracking@amazon.com`, `budgets@costalerts.amazonaws.com`, and the
/// like. This sweep re-evaluates the drafts already in the queue against the
/// current pure evaluator and moves the now-skippable ones to the skip log
/// (recoverable via "Draft anyway"), clearing their notifications.
///
/// **Scope (sender-based only).** Pending drafts persist only the source sender
/// addresses (`sourceFrom` / `sourceReplyTo`), not the bounded header fields the
/// live gate also fetches, so this catches no-reply and transactional senders
/// deterministically and offline. Header-only bulk/list mail — newsletters that
/// are recognised solely by `List-Id` / `List-Unsubscribe` / `Precedence` (e.g.
/// Zillow, Substack) — is intentionally **out of scope** for v1; a header-refetch
/// variant that re-derives those signals from the server is a possible later
/// enhancement.
extension AppState {

    /// Runs the one-time pre-gate draft sweep if it has not run before, then marks
    /// it done so it never runs again. Guarded by the persisted
    /// `hasRunPreGateDraftSweep` flag (default `false` on installs that predate the
    /// gate). Synchronous and offline — it reasons only over stored sender signals
    /// and touches no network. Invoked at launch outside Prowl hunt mode.
    func runPreGateDraftSweepIfNeeded() {
        guard !hasRunPreGateDraftSweep else { return }

        let result = runPreGateDraftSweep()

        guard result.completed else {
            logger.error("Pre-gate draft sweep left incomplete after a selected draft could not be swept")
            return
        }

        hasRunPreGateDraftSweep = true
        do {
            try persistSettingsSync(buildSettings())
        } catch {
            // The in-memory flag stays set for this session; if the write failed
            // the sweep simply re-runs next launch — it is idempotent (already
            // swept drafts are gone from the queue, so a second pass is a no-op).
            logger.error("Failed to persist pre-gate draft sweep flag: \(error.localizedDescription)")
        }

        if result.sweptCount > 0 {
            logger.info("Pre-gate draft sweep moved \(result.sweptCount) now-skippable draft(s) to the skip log")
        } else {
            logger.info("Pre-gate draft sweep found no now-skippable drafts")
        }
    }

    /// Re-evaluates each eligible pending draft against the current reply-worthiness
    /// evaluator, moving the now-skippable ones to the skip log. Returns how many
    /// drafts were swept. Iterates a snapshot because `removePendingDraft` mutates
    /// `pendingDrafts`.
    @discardableResult
    private func runPreGateDraftSweep() -> PreGateDraftSweepResult {
        let snapshot = pendingDrafts
        var sweptCount = 0
        var completed = true

        for draft in snapshot {
            guard isPreGateSweepCandidate(draft) else { continue }

            // The skip record needs a concrete account + mailbox to key off and to
            // re-draft from later. Without them, leave the draft in the queue rather
            // than dropping it into an unrecoverable skip entry.
            guard let account = draft.sourceAccountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !account.isEmpty,
                  let mailbox = Self.sourceMailbox(for: draft) else { continue }

            // Reconstruct the source message from the draft's stored fields. `date`
            // is unused by the skip record, so an empty string is fine here.
            let message = MailMessage(
                id: draft.id,
                uidValidity: draft.sourceUIDValidity,
                from: draft.sourceFrom,
                replyTo: draft.sourceReplyTo,
                subject: draft.sourceSubject,
                date: "",
                messageID: draft.sourceMessageID
            )

            guard senderRuleDecision(for: message) != .forceDraft else { continue }

            let signals = ReplyWorthinessSignals(
                fromEmail: draft.sourceFrom?.email,
                replyToEmail: draft.sourceReplyTo?.email
            )
            guard let reason = ReplyWorthiness.evaluate(signals).skipReason else { continue }

            do {
                try recordSkipSync(message, reason: reason, account: account, mailbox: mailbox)
            } catch {
                completed = false
                logger.error("Pre-gate sweep failed to persist a recoverable skipped entry: \(error.localizedDescription)")
                continue
            }

            do {
                try removePendingDraft(draft, removeNotification: true)
                sweptCount += 1
            } catch {
                completed = false
                logger.error("Pre-gate sweep failed to remove a swept draft: \(error.localizedDescription)")
                removeSkippedMessageIfNeeded(message, account: account, mailbox: mailbox)
            }
        }

        return PreGateDraftSweepResult(sweptCount: sweptCount, completed: completed)
    }

    /// Whether a draft is eligible for the pre-gate sweep. Only plain reply drafts
    /// are swept; anything the user has invested in — an authored follow-up
    /// (item 51), a draft they edited (item 19), a draft with a queued offline
    /// dispatch (item 27), or one flagged as needing their input (item 13) — is
    /// never touched.
    private func isPreGateSweepCandidate(_ draft: Draft) -> Bool {
        if draft.generatedAt >= preGateDraftSweepCutoff { return false }
        if draft.replyWorthinessOverride == true { return false }
        if draft.isAuthored { return false }
        if draft.wasEdited { return false }
        if draft.offlineQueuedDispatch != nil { return false }
        if draft.needsInfo != nil { return false }
        return true
    }

    private func removeSkippedMessageIfNeeded(_ message: MailMessage, account: String, mailbox: Mailbox) {
        let entry = SkippedMessage(message: message, mailbox: mailbox, account: account, reason: .noReplySender)
        guard skippedMessages.contains(where: { $0.id == entry.id }) else { return }
        do {
            try removeSkippedMessageSync(entry)
        } catch {
            logger.error("Pre-gate sweep failed to roll back a skipped entry: \(error.localizedDescription)")
        }
    }
}
