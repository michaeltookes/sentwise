import SentwiseMail
import Foundation
import os

private let inlineDraftEditingLogger = Logger(subsystem: "com.tookes.Sentwise", category: "PendingDrafts")

extension AppState {

    /// Applies a user's inline edit to a queued draft's reply body (item 19) and
    /// persists it, so the edited text is what later dispatches and the edit
    /// survives a relaunch. Captures the assistant's original body the first time
    /// it diverges (for future voice tuning). Returns the updated draft, the
    /// unchanged draft when the text is identical, or `nil` if the edit could not
    /// be applied durably. On write failure the in-memory edit is rolled back so
    /// memory and disk stay consistent.
    @discardableResult
    func updatePendingDraftBody(_ draft: Draft, to newBody: String) -> Draft? {
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else {
            clearPendingDraftEdits(identity: draft.identity)
            return nil
        }
        let finalizedBody = finalizedBodyForManualDraftEdit(pendingDrafts[index], editedBody: newBody)
        guard pendingDrafts[index].body != finalizedBody else {
            clearPendingDraftBodyEdit(identity: draft.identity)
            return pendingDrafts[index]
        }

        let previous = pendingDrafts[index]
        pendingDrafts[index].applyEditedBody(finalizedBody)
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts[index] = previous
            pendingDraftUncommittedEditIDs.insert(draft.identity)
            pendingDraftUncommittedEditBodies[draft.identity] = newBody
            inlineDraftEditingLogger.error("Failed to persist edited pending draft: \(error.localizedDescription)")
            approvalError = Self.draftMessage(for: error)
            return nil
        }
        clearPendingDraftBodyEdit(identity: draft.identity)
        notifier.refreshNotification(for: pendingDrafts[index], sendBehavior: sendBehavior)
        return pendingDrafts[index]
    }

    private func finalizedBodyForManualDraftEdit(_ draft: Draft, editedBody: String) -> String {
        guard draft.notReplyWorthy != nil,
              draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return editedBody
        }
        return finalizedDraftBody(editedBody)
    }

    /// Marks whether a pending draft card has editor text that has not yet been
    /// persisted. Notification approvals check this before dispatching.
    func notePendingDraftBodyEdit(_ draft: Draft, editedBody: String) {
        guard let queued = pendingDrafts.first(where: { $0.identity == draft.identity }) else {
            clearPendingDraftEdits(identity: draft.identity)
            return
        }
        if queued.body == editedBody {
            clearPendingDraftBodyEdit(identity: draft.identity)
        } else {
            pendingDraftUncommittedEditIDs.insert(draft.identity)
            pendingDraftUncommittedEditBodies[draft.identity] = editedBody
        }
    }

    func notePendingDraftRecipientEdit(_ draft: Draft, recipients: [MailAddress]) {
        notePendingDraftRecipientEdit(
            draft,
            recipientEdit: RecipientParseResult(recipients: recipients, hasInvalidEntries: false)
        )
    }

    func notePendingDraftRecipientEdit(_ draft: Draft, recipientEdit: RecipientParseResult) {
        guard let queued = pendingDrafts.first(where: { $0.identity == draft.identity }) else {
            clearPendingDraftEdits(identity: draft.identity)
            return
        }
        guard queued.isAuthored else {
            clearPendingDraftRecipientEdit(identity: draft.identity)
            return
        }
        let deduped = Self.dedupedRecipients(recipientEdit.recipients)
        if recipientEdit.hasInvalidEntries {
            pendingDraftInvalidRecipientEditIDs.insert(draft.identity)
            pendingDraftUncommittedEditIDs.insert(draft.identity)
            pendingDraftUncommittedEditRecipients.removeValue(forKey: draft.identity)
            return
        }
        pendingDraftInvalidRecipientEditIDs.remove(draft.identity)
        if queued.authoredRecipients == deduped {
            clearPendingDraftRecipientEdit(identity: draft.identity)
        } else {
            pendingDraftUncommittedEditIDs.insert(draft.identity)
            pendingDraftUncommittedEditRecipients[draft.identity] = deduped
        }
    }

    /// Persists any inline editor text already registered with the debounce
    /// guard. Used during application termination when SwiftUI may not run
    /// `onDisappear` before the process exits.
    func flushPendingDraftBodyEdits() {
        let edits = pendingDraftUncommittedEditBodies
        for (identity, editedBody) in edits {
            guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else {
                clearPendingDraftBodyEdit(identity: identity)
                continue
            }
            updatePendingDraftBody(draft, to: editedBody)
        }
    }

    func flushPendingDraftRecipientEdits() {
        let edits = pendingDraftUncommittedEditRecipients
        for (identity, recipients) in edits {
            guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else {
                clearPendingDraftEdits(identity: identity)
                continue
            }
            updatePendingDraftRecipients(draft, to: recipients)
        }
        for identity in Array(pendingDraftInvalidRecipientEditIDs)
            where !pendingDrafts.contains(where: { $0.identity == identity }) {
            clearPendingDraftEdits(identity: identity)
        }
    }

    func flushPendingDraftEdits() {
        flushPendingDraftBodyEdits()
        flushPendingDraftRecipientEdits()
    }

    func clearPendingDraftBodyEdit(identity: String) {
        pendingDraftUncommittedEditBodies.removeValue(forKey: identity)
        refreshPendingDraftUncommittedEditID(identity)
    }

    func clearPendingDraftRecipientEdit(identity: String) {
        pendingDraftUncommittedEditRecipients.removeValue(forKey: identity)
        pendingDraftInvalidRecipientEditIDs.remove(identity)
        refreshPendingDraftUncommittedEditID(identity)
    }

    func clearPendingDraftEdits(identity: String) {
        pendingDraftUncommittedEditBodies.removeValue(forKey: identity)
        pendingDraftUncommittedEditRecipients.removeValue(forKey: identity)
        pendingDraftInvalidRecipientEditIDs.remove(identity)
        pendingDraftUncommittedEditIDs.remove(identity)
    }

    private func refreshPendingDraftUncommittedEditID(_ identity: String) {
        if pendingDraftUncommittedEditBodies[identity] != nil
            || pendingDraftUncommittedEditRecipients[identity] != nil
            || pendingDraftInvalidRecipientEditIDs.contains(identity) {
            pendingDraftUncommittedEditIDs.insert(identity)
        } else {
            pendingDraftUncommittedEditIDs.remove(identity)
        }
    }

    func flushPendingDraftRecipientEdit(for draft: Draft) -> Draft? {
        guard !pendingDraftInvalidRecipientEditIDs.contains(draft.identity) else {
            approvalError = "Fix invalid recipient addresses before approving this follow-up."
            return nil
        }
        guard let recipients = pendingDraftUncommittedEditRecipients[draft.identity] else {
            return pendingDrafts.first { $0.identity == draft.identity } ?? draft
        }
        return updatePendingDraftRecipients(draft, to: recipients)
    }

    /// Applies the current inline editor contents before dispatching. Approval
    /// stops if the edited body cannot be persisted, so the user never sends or
    /// saves a different body from the one shown in the review UI.
    func approvePendingDraft(_ draft: Draft, withEditedBody editedBody: String, force: Bool = false) async {
        guard let updated = updatePendingDraftBody(draft, to: editedBody) else { return }
        guard let withRecipients = flushPendingDraftRecipientEdit(for: updated) else { return }
        await approveDraft(withRecipients, force: force)
    }
}
