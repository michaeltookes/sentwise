import SentwiseMail
import Foundation
import os

private let needsInfoAnswersLogger = Logger(subsystem: "com.tookes.Sentwise", category: "PendingDrafts")

/// Answer-in-place actions for `NEEDS_INFO` drafts (item 85): attach the user's
/// typed facts to the queued draft, re-draft through the existing regenerate
/// pipeline with those facts injected, and — after the loop fails twice — fall
/// back to a hand-written reply seeded with the answers.
///
/// **Privacy:** the supplied facts are local-only free text. They are persisted
/// on the draft and injected into the same stateless drafting call as the mail
/// content, but are never logged or recorded in the activity history.
extension AppState {

    /// Merges a fresh card round of answers into the draft's stored facts (never
    /// dropping a prior round) and re-drafts through `regeneratePendingDraft`, which
    /// re-injects the accumulated facts into the generator prompt. No new pipeline —
    /// the same stale/account guards and persistence path apply.
    func redraftPendingDraftWithAnswers(_ draft: Draft, round: UserSuppliedFacts) async {
        guard let updated = attachUserSuppliedFacts(round, to: draft) else { return }
        guard updated.wasAnswered else {
            approvalError = "Add at least one answer before re-drafting."
            return
        }
        await regeneratePendingDraft(updated)
    }

    /// Persists the accumulated facts onto the queued draft so a re-draft (and a
    /// relaunch) can re-inject them. Returns the updated draft, or `nil` if it is no
    /// longer queued or the write failed.
    @discardableResult
    func attachUserSuppliedFacts(_ round: UserSuppliedFacts, to draft: Draft) -> Draft? {
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else {
            return nil
        }
        let merged = (pendingDrafts[index].userSuppliedFacts ?? UserSuppliedFacts()).merging(round: round)
        guard pendingDrafts[index].userSuppliedFacts != merged else { return pendingDrafts[index] }

        let previous = pendingDrafts[index]
        pendingDrafts[index].userSuppliedFacts = merged
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts[index] = previous
            needsInfoAnswersLogger.error("Failed to persist supplied facts: \(error.localizedDescription)")
            approvalError = Self.draftMessage(for: error)
            return nil
        }
        return pendingDrafts[index]
    }

    /// The "write it yourself" escape (item 85): folds the current answers into the
    /// draft, clears the `NEEDS_INFO` flag, and seeds the reply body with those
    /// answers so the card's normal editable reply fields open pre-filled. The user
    /// edits and approves from there.
    @discardableResult
    func writeReplyYourself(_ draft: Draft, currentRound: UserSuppliedFacts = UserSuppliedFacts()) -> Draft? {
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else {
            return nil
        }
        let merged = (pendingDrafts[index].userSuppliedFacts ?? UserSuppliedFacts()).merging(round: currentRound)
        let seed = merged.replyBodySeed

        let previous = pendingDrafts[index]
        pendingDrafts[index].userSuppliedFacts = merged
        pendingDrafts[index].needsInfo = nil
        pendingDrafts[index].body = seed.isEmpty ? "" : finalizedDraftBody(seed)
        pendingDrafts[index].originalBody = nil
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts[index] = previous
            needsInfoAnswersLogger.error("Failed to persist hand-written reply seed: \(error.localizedDescription)")
            approvalError = Self.draftMessage(for: error)
            return nil
        }
        clearPendingDraftEdits(identity: draft.identity)
        notifier.refreshNotification(for: pendingDrafts[index], sendBehavior: sendBehavior)
        return pendingDrafts[index]
    }
}
