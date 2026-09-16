import Foundation

extension PersistenceProvider {

    /// Purges mail artifacts that belong to one mailbox account while leaving
    /// other saved accounts' records intact. Legacy records that predate account
    /// tagging are removed only when `includeUnscopedArtifacts` is true, which the
    /// AppState layer reserves for the currently active account.
    func purgeAccountScopedArtifacts(
        for accountEmail: String,
        includeUnscopedArtifacts: Bool
    ) throws {
        let account = SavedMailAccount.normalizedEmail(accountEmail)
        guard !account.isEmpty else { return }

        if includeUnscopedArtifacts {
            try removeVoiceProfile()
        }

        var processed = loadProcessedMessages()
        processed.removeAccount(account)
        try saveProcessedMessagesSync(processed)

        let pendingDrafts = loadPendingDrafts().filter {
            !Self.draft($0, belongsTo: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
        }
        try savePendingDraftsSync(pendingDrafts)

        let skippedMessages = loadSkippedMessages().filter {
            SavedMailAccount.normalizedEmail($0.account) != account
        }
        try saveSkippedMessagesSync(skippedMessages)

        let approved = loadApprovedDraftIdentities().filter {
            !Self.draftIdentity($0, belongsTo: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
        }
        try saveApprovedDraftIdentitiesSync(approved)

        let activity = loadActivityEvents().filter {
            !Self.activity($0, belongsTo: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
        }
        try saveActivityEventsSync(activity)

        let feedback = loadDraftFeedback().filter {
            !Self.feedback($0, belongsTo: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
        }
        try saveDraftFeedbackSync(feedback)
    }

    private static func draft(
        _ draft: Draft,
        belongsTo account: String,
        includeUnscopedArtifacts: Bool
    ) -> Bool {
        let draftAccount = SavedMailAccount.normalizedEmail(draft.sourceAccountEmail ?? "")
        if draftAccount.isEmpty { return includeUnscopedArtifacts }
        return draftAccount == account
    }

    private static func draftIdentity(
        _ identity: String,
        belongsTo account: String,
        includeUnscopedArtifacts: Bool
    ) -> Bool {
        let components = identity.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count > 1, let first = components.first else {
            return includeUnscopedArtifacts
        }
        let identityAccount = SavedMailAccount.normalizedEmail(String(first))
        if identityAccount.isEmpty || identityAccount == "?" {
            return includeUnscopedArtifacts
        }
        return identityAccount == account
    }

    private static func activity(
        _ event: ActivityEvent,
        belongsTo account: String,
        includeUnscopedArtifacts: Bool
    ) -> Bool {
        let eventAccount = SavedMailAccount.normalizedEmail(event.account ?? "")
        if eventAccount.isEmpty { return includeUnscopedArtifacts }
        return eventAccount == account
    }

    private static func feedback(
        _ record: DraftFeedbackRecord,
        belongsTo account: String,
        includeUnscopedArtifacts: Bool
    ) -> Bool {
        let recordAccount = SavedMailAccount.normalizedEmail(record.sourceAccountEmail ?? "")
        if recordAccount.isEmpty { return includeUnscopedArtifacts }
        return recordAccount == account
    }
}
