import Foundation

private struct AccountArtifactSnapshot {
    let voiceProfile: VoiceProfile?
    let processedMessages: ProcessedMessages
    let pendingDrafts: [Draft]
    let skippedMessages: [SkippedMessage]
    let approvedDraftIdentities: Set<String>
    let activityEvents: [ActivityEvent]
    let draftFeedback: [DraftFeedbackRecord]

    init(_ persistence: PersistenceProvider) {
        voiceProfile = persistence.loadVoiceProfile()
        processedMessages = persistence.loadProcessedMessages()
        pendingDrafts = persistence.loadPendingDrafts()
        skippedMessages = persistence.loadSkippedMessages()
        approvedDraftIdentities = persistence.loadApprovedDraftIdentities()
        activityEvents = persistence.loadActivityEvents()
        draftFeedback = persistence.loadDraftFeedback()
    }

    func restore(to persistence: PersistenceProvider) {
        if let voiceProfile {
            persistence.saveVoiceProfile(voiceProfile)
        } else {
            try? persistence.removeVoiceProfile()
        }
        try? persistence.updateProcessedMessagesSync { $0 = processedMessages }
        try? persistence.savePendingDraftsSync(pendingDrafts)
        try? persistence.saveSkippedMessagesSync(skippedMessages)
        try? persistence.saveApprovedDraftIdentitiesSync(approvedDraftIdentities)
        try? persistence.updateActivityEventsSync { $0 = activityEvents }
        try? persistence.updateDraftFeedbackSync { $0 = draftFeedback }
    }
}

extension PersistenceProvider {

    /// Purges every mail-content-bearing artifact while leaving account settings
    /// and credentials alone. This is used when the app no longer has a selected
    /// mailbox but retained mail records can still exist locally.
    func purgeAllMailArtifacts() throws {
        try removeVoiceProfile()
        try removeProcessedMessages()
        try removePendingDrafts()
        try removeSkippedMessages()
        try removeApprovedDraftIdentities()
        try removeActivityEvents()
        try removeDraftFeedback()
    }

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
        let snapshot = AccountArtifactSnapshot(self)

        do {
            if includeUnscopedArtifacts {
                try removeVoiceProfile()
            }

            try updateProcessedMessagesSync { processed in
                processed.removeAccount(account)
            }

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

            try updateActivityEventsSync { events in
                events.removeAll {
                    Self.activity($0, belongsTo: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
                }
            }

            try updateDraftFeedbackSync { records in
                records.removeAll {
                    Self.feedback($0, belongsTo: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
                }
            }
        } catch {
            snapshot.restore(to: self)
            throw error
        }
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
        guard let accountHash = DraftFeedbackRecord.hashedAccount(account),
              let recordAccountHash = record.sourceAccountHash,
              !recordAccountHash.isEmpty else {
            return includeUnscopedArtifacts
        }
        return recordAccountHash == accountHash
    }
}
