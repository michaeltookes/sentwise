import SentwiseMail
import Foundation

/// Draft provenance helpers split out to keep the generation/queueing files
/// within lint limits.
extension AppState {

    /// Builds a watcher-selected reply and appends it to the pending queue. Unlike
    /// `generateDraft`, this avoids Settings preview state.
    @discardableResult
    func draftAndEnqueue(
        _ message: MailMessage,
        mailbox: Mailbox = .inbox,
        requireWatching: Bool = true,
        credentials capturedCredentials: MailAccountCredentials? = nil,
        replyWorthinessOverride: Bool = false
    ) async throws -> Bool {
        guard var draft = try await makePendingDraft(
            for: message,
            mailbox: mailbox,
            requireWatching: requireWatching,
            credentials: capturedCredentials
        ) else { return false }
        draft.replyWorthinessOverride = replyWorthinessOverride
        if replyWorthinessOverride {
            draft.replyWorthinessOverrideSource = DraftReplyWorthinessOverrideSource(
                account: draft.sourceAccountEmail ?? capturedCredentials?.email ?? mailCredentials.email,
                mailbox: mailbox,
                message: message
            )
        }
        try enqueuePendingDraft(draft)
        return true
    }

    func preserveRegenerationProvenance(from draft: Draft, on replacement: inout Draft) {
        replacement.generatedAt = draft.generatedAt
        replacement.regeneratedAt = Date()
        replacement.replyWorthinessOverride = draft.replyWorthinessOverride
        preserveUserSuppliedFacts(from: draft, on: &replacement)
        guard draft.replyWorthinessOverride == true else { return }
        replacement.replyWorthinessOverrideSource = draft.replyWorthinessOverrideSource
            ?? replyWorthinessOverrideSource(from: draft)
    }

    /// Carries the user's answered facts across a re-draft (item 85) and tracks how
    /// many answered re-drafts still came back `NEEDS_INFO`, so the card can offer
    /// the "write it yourself" escape after the second failure. The counter only
    /// advances when the *answered* re-draft is still flagged; a re-draft that
    /// produces a usable reply leaves it where it was.
    private func preserveUserSuppliedFacts(from draft: Draft, on replacement: inout Draft) {
        replacement.userSuppliedFacts = draft.userSuppliedFacts
        let answeredThisRound = !(draft.userSuppliedFacts?.isEmpty ?? true)
        if answeredThisRound, replacement.needsInfo != nil {
            replacement.answeredRedraftCount = draft.answeredRedraftFailures + 1
        } else {
            replacement.answeredRedraftCount = draft.answeredRedraftCount
        }
    }

    private func replyWorthinessOverrideSource(from draft: Draft) -> DraftReplyWorthinessOverrideSource? {
        guard let account = draft.sourceAccountEmail,
              let mailbox = draft.sourceMailbox else { return nil }
        return DraftReplyWorthinessOverrideSource(
            account: account,
            mailbox: mailbox,
            id: draft.id,
            uidValidity: draft.sourceUIDValidity,
            messageID: draft.sourceMessageID
        )
    }
}
