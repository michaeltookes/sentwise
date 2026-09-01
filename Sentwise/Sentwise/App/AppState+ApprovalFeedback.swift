import Foundation
import os

private let feedbackLogger = Logger(subsystem: "com.tookes.Sentwise", category: "ApprovalFeedback")

/// On-device approval-signal capture (item 83, Phase 1). Every terminal draft
/// action — approved-as-is, approved-after-edit, denied, or abandoned from a
/// manual preview — is recorded as a durable, privacy-safe `DraftFeedbackRecord`
/// so later phases (2–4) and items 84/35 have a substrate to read. Phase 1 only
/// writes the store; nothing here learns from it or leaves the machine.
///
/// **Privacy:** records hold codes, numbers, and hashes only, with the single
/// exception of a deny's "Other" free text (see `DenyReason`). The draft is
/// referenced by a SHA-256 hash of its identity, never by address/subject/body.
///
/// **Hunt mode:** the store routes through the injected `persistence`, which is an
/// in-memory `MemoryPersistenceProvider` during Prowl hunts — so a hunt writes to
/// a no-op/in-memory sink with zero disk side effects, matching how pending
/// drafts and the activity log behave in hunt mode.
extension AppState {

    /// Maximum feedback records kept; oldest dropped past this so the append-only
    /// store can't grow unbounded. Larger than the activity log because these are
    /// tiny (codes/hashes) and their value is the trend over many actions.
    var draftFeedbackLogLimit: Int { 2000 }

    /// Inserts `record` at the front (newest first), evicts the oldest past the
    /// cap, and persists. Never throws — a feedback-store write must not fail an
    /// approve or deny.
    func recordDraftFeedback(_ record: DraftFeedbackRecord) {
        draftFeedbackRecords.insert(record, at: 0)
        if draftFeedbackRecords.count > draftFeedbackLogLimit {
            draftFeedbackRecords.removeLast(draftFeedbackRecords.count - draftFeedbackLogLimit)
        }
        persistence.saveDraftFeedback(draftFeedbackRecords)
        feedbackLogger.info("Recorded draft feedback (\(record.outcome.rawValue, privacy: .public))")
    }

    /// Records an approval outcome for a draft that just dispatched (item 83).
    /// `approvedAsIs` vs. `approvedAfterEdit` comes from item 19's `wasEdited`;
    /// the edit magnitude is computed only for edited approvals.
    func recordApprovalFeedback(for draft: Draft, sendBehavior: SendBehavior) {
        let outcome: DraftFeedbackOutcome = draft.wasEdited ? .approvedAfterEdit : .approvedAsIs
        let magnitude = draft.wasEdited
            ? DraftEditMagnitude.ratio(original: draft.originalBody ?? "", final: draft.body)
            : nil
        recordDraftFeedback(DraftFeedbackRecord(
            outcome: outcome,
            dispatch: DraftFeedbackDispatch(sendBehavior),
            editMagnitude: magnitude,
            denyReason: nil,
            provenance: draft.feedbackProvenance,
            answeredNeedsInfo: draft.wasAnswered,
            draftIdentityHash: DraftFeedbackRecord.hashedIdentity(draft.identity)
        ))
    }

    /// Records a deny outcome with its reason (item 83). `reason` is `nil` only
    /// for the legacy/direct `denyDraft` path, which carries no reason.
    func recordDenyFeedback(for draft: Draft, reason: DenyReason?) {
        recordDraftFeedback(DraftFeedbackRecord(
            outcome: .denied,
            dispatch: nil,
            editMagnitude: nil,
            denyReason: reason,
            provenance: draft.feedbackProvenance,
            answeredNeedsInfo: draft.wasAnswered,
            draftIdentityHash: DraftFeedbackRecord.hashedIdentity(draft.identity)
        ))
    }

    /// Records a manually generated preview that the user closed without sending
    /// or saving. Watcher/queued drafts use the explicit deny path instead.
    func recordDraftPreviewAbandonment(for draft: Draft) {
        guard draft.manualPreview == true else { return }
        recordDraftFeedback(DraftFeedbackRecord(
            outcome: .abandoned,
            dispatch: nil,
            editMagnitude: nil,
            denyReason: nil,
            provenance: draft.feedbackProvenance,
            answeredNeedsInfo: draft.wasAnswered,
            draftIdentityHash: DraftFeedbackRecord.hashedIdentity(draft.identity)
        ))
    }
}
