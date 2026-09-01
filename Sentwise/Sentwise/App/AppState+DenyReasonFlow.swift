import Foundation

/// A deny awaiting the user's reason (item 83, Phase 1). Carries the draft being
/// denied plus the picker's initial selection (the last-used reason, per the
/// friction guard). Identifiable by draft identity so it drives a SwiftUI sheet.
struct DenyReasonPrompt: Identifiable, Equatable {
    let draft: Draft
    /// The reason pre-selected when the picker opens (last-used, else the first
    /// preset).
    var defaultCode: DenyReasonCode
    /// The "Other" free text pre-filled when the last-used reason was `.other`.
    var defaultOtherText: String

    var id: String { draft.identity }
}

/// The deny-reason picker state machine (item 83, Phase 1). Hitting Deny/Discard
/// presents a single-select reason picker *before* the deny finalizes; the deny
/// cannot complete until a reason is chosen (and, for "Other", non-empty text is
/// entered). A per-session "don't ask again" fast path and a remembered last
/// reason keep heavy deniers out of a modal on every deny.
extension AppState {

    /// Entry point for a user-initiated Deny/Discard (item 83). Presents the
    /// reason picker unless the user silenced it this session — in which case the
    /// remembered reason is reused and the deny finalizes immediately (still
    /// recorded). Returns `true` when the picker was presented, so callers (e.g.
    /// the notification path) can surface the review window that hosts it.
    /// A no-op when the draft isn't pending or is mid-approval.
    @discardableResult
    func requestDenyDraft(_ draft: Draft) -> Bool {
        guard !approvingDraftIDs.contains(draft.identity),
              pendingDrafts.contains(where: { $0.identity == draft.identity }) else {
            return false
        }
        // Friction guard: silence the picker for the rest of this app run.
        if denyReasonPromptSuppressedThisSession, let remembered = lastUsedDenyReason {
            finalizeDenyDraft(draft, reason: remembered)
            return false
        }
        denyReasonPrompt = DenyReasonPrompt(
            draft: draft,
            defaultCode: lastUsedDenyReason?.code ?? .notWorthReplying,
            defaultOtherText: lastUsedDenyReason?.code == .other
                ? (lastUsedDenyReason?.otherText ?? "")
                : ""
        )
        return true
    }

    /// Finalizes the pending deny with the chosen reason (item 83). Remembers the
    /// reason for the session and, when the user asked, silences the picker for the
    /// rest of this app run. Refuses to complete an "Other" reason with empty text
    /// (the UI also disables Confirm in that case). A no-op if no deny is pending.
    func confirmDenyReason(code: DenyReasonCode, otherText: String, dontAskAgain: Bool) {
        guard let prompt = denyReasonPrompt else { return }
        let trimmedOther = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        if code == .other, trimmedOther.isEmpty { return }

        let reason = DenyReason(code: code, otherText: code == .other ? trimmedOther : nil)
        lastUsedDenyReason = reason
        if dontAskAgain {
            denyReasonPromptSuppressedThisSession = true
        }
        denyReasonPrompt = nil
        finalizeDenyDraft(prompt.draft, reason: reason)
    }

    /// Aborts the pending deny cleanly — the draft stays queued, nothing recorded.
    func cancelDenyReason() {
        denyReasonPrompt = nil
    }
}
