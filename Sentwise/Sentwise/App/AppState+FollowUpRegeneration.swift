import SentwiseMail
import Foundation

/// Authored follow-up re-drafting, split from `AppState+PendingDrafts` so the
/// thread regeneration file stays within lint limits.
extension AppState {

    func regenerateAuthoredFollowUpDraft(_ draft: Draft) async {
        guard let draft = flushPendingDraftRecipientEdit(for: draft) else { return }
        guard let context = Self.followUpContext(for: draft) else {
            approvalError = Self.draftMessage(for: DraftError.sourceMessageUnavailable)
            return
        }
        await refreshManagedQuotaIfLicenseStatusStale()
        guard let llmConfiguration = currentDraftLLMConfiguration else {
            approvalError = Self.draftMessage(for: DraftError.llmUnavailable)
            return
        }
        let credentials: MailAccountCredentials
        do {
            // Multi-account (item 99): authored follow-ups regenerate from the
            // draft's source account, just like approval and reply regeneration.
            credentials = try dispatchCredentials(forDraft: draft)
        } catch {
            approvalError = Self.draftMessage(for: error)
            return
        }

        approvalError = nil
        approvingDraftIDs.insert(draft.identity)
        defer { approvingDraftIDs.remove(draft.identity) }

        do {
            let outcome = try await makeFollowUpOutcome(
                context: context,
                llmConfiguration: llmConfiguration,
                userSuppliedFacts: draft.userSuppliedFacts,
                accountEmail: credentials.email
            )
            guard currentDraftLLMConfiguration == llmConfiguration else {
                approvalError = "The draft could not be regenerated because account settings changed."
                return
            }
            _ = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
            var replacement = makeAuthoredDraft(AuthoredDraftSpec(
                outcome: outcome,
                recipients: draft.authoredRecipients ?? [],
                subject: draft.replySubject,
                model: llmConfiguration.model,
                credentials: credentials,
                followUpContext: context,
                id: draft.id
            ))
            preserveRegenerationProvenance(from: draft, on: &replacement)
            _ = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
            try replacePendingDraft(draft, with: replacement, staleReason: nil)
        } catch {
            await reconcileManagedAccountState(after: error, provider: llmConfiguration.provider)
            approvalError = Self.draftMessage(for: error)
        }
    }

    private static func followUpContext(for draft: Draft) -> FollowUpDraftContext? {
        if let context = draft.followUpContext, !context.isEmpty {
            return context
        }
        if let transcript = draft.followUpTranscript, !transcript.isEmpty {
            return .transcript(transcript)
        }
        guard draft.isAuthored,
              let body = draft.incomingBody,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let transcript = TranscriptParser.parse(body, format: .plainText)
        return transcript.isEmpty ? nil : .transcript(transcript)
    }
}
