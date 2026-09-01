import SentwiseMail
import Foundation

/// Preview-sheet draft dispatch. Kept separate from generation so the draft
/// generation extension stays within lint limits.
extension AppState {

    /// Dispatches a preview sheet's displayed draft without reading mutable
    /// global preview state. The sheet owns its own progress/error UI.
    ///
    /// Unless `force` is set, the draft's thread is re-checked first (item 12);
    /// if it changed since the draft was generated, this throws
    /// `DraftDispatchError.staleThread` so the sheet can warn before sending.
    /// Passing `force: true` is the user's "send anyway" override.
    func approveDraftPreview(
        _ draft: Draft,
        sendBehavior approvalSendBehavior: SendBehavior? = nil,
        force: Bool = false
    ) async throws -> String {
        let credentials = try previewDraftCredentials(for: draft)
        let effectiveSendBehavior = approvalSendBehavior ?? sendBehavior
        let dispatchCredentials = try await previewDispatchCredentials(
            for: draft,
            credentials: credentials,
            force: force
        )

        let confirmation: String
        switch effectiveSendBehavior {
        case .autoSend:
            try await performSend(draft, credentials: dispatchCredentials)
            clearGeneratedDraftIfDisplayed(draft)
            confirmation = "Sent."
        case .saveAsDraft:
            try await performSave(draft, credentials: dispatchCredentials)
            confirmation = "Saved to your Drafts."
        }
        recordApprovalFeedback(for: draft, sendBehavior: effectiveSendBehavior)
        return confirmation
    }

    /// Records a canceled preview auto-send countdown in the same audit stream as
    /// queued countdown cancellation.
    func recordDraftPreviewSendCancellation(for draft: Draft) {
        recordDraftActivity(.sendCanceled, for: draft)
    }

    private func previewDraftCredentials(for draft: Draft) throws -> MailAccountCredentials {
        guard !draft.isFlagged else {
            throw DraftError.needsUserInput
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            throw DraftDispatchError.missingCredentials
        }
        guard draftMatchesCurrentAccount(draft, credentials: credentials) else {
            clearGeneratedDraftIfDisplayed(draft)
            throw DraftDispatchError.accountMismatch
        }
        guard draftSourceAllowsReplyDispatch(draft) else {
            clearGeneratedDraftIfDisplayed(draft)
            throw DraftError.unsupportedSourceMailbox
        }
        return credentials
    }

    private func previewDispatchCredentials(
        for draft: Draft,
        credentials: MailAccountCredentials,
        force: Bool
    ) async throws -> MailAccountCredentials {
        guard !force else { return credentials }
        let verdict = await threadStalenessVerdict(for: draft, credentials: credentials)
        let currentCredentials = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
        if case .stale(let reason) = verdict {
            recordDraftActivity(.staleWarning, for: draft, staleReason: reason)
            throw DraftDispatchError.staleThread(reason)
        }
        return currentCredentials
    }

    private func clearGeneratedDraftIfDisplayed(_ draft: Draft) {
        // Compare by identity, not full equality: an inline-edited draft (item 19)
        // differs from the stored `generatedDraft` only in body, yet still refers
        // to the same displayed draft that should be cleared.
        if generatedDraft?.identity == draft.identity {
            generatedDraft = nil
        }
    }
}
