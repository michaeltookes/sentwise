import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "LocalDataPurge")

struct LocalDataEraseResult: Equatable {
    let persistenceError: String?
    let keychainError: String?
    let preferenceError: String?

    var succeeded: Bool {
        persistenceError == nil && keychainError == nil && preferenceError == nil
    }
}

/// Local-data purge and full erase on `AppState` (backlog item 96 / security
/// finding A-L2). Two operations, both routed through the persistence seam so
/// they are disk-free under the in-memory provider used by Prowl hunts and tests:
///
/// * `purgeLocalMailArtifacts(for:includeUnscopedArtifacts:)` deletes the
///   target account's mail-content-bearing records — processed-message dedup,
///   pending drafts, recoverable skips, approved-draft tombstones, activity
///   history, and approval-signal feedback — leaving other saved accounts intact.
///   The legacy single voice profile is removed only when purging the active
///   account (`includeUnscopedArtifacts`).
/// * `eraseAllLocalData()` wipes everything under Application Support *and* every
///   per-account Keychain entry, then returns the running app to a coherent
///   first-run state without a relaunch.
///
/// ## Dedup / re-add decision (item 96 requires deciding + documenting)
/// A purge removes `ProcessedMessages.json` (the watcher's per-account dedup and
/// baseline). The chosen behavior is to **purge the dedup with the account** and
/// rely on the watcher's baseline mechanism to bound re-drafting: on the next
/// connect the watcher re-seeds its baseline from the mailbox's current state
/// (`AppState+Watcher` treats everything at/older than the baseline as historical
/// and only drafts mail arriving *after* the baseline). So a re-added account does
/// **not** re-draft old inbox mail — the flood the naive "lost dedup" worry
/// implies never happens. The deliberate trade-off: any message that arrived while
/// disconnected and is still unactioned in the inbox at re-add time is folded into
/// the new baseline and will not be drafted. That matches the product's contract
/// (Sentwise drafts mail that arrives while it is connected and watching), and it
/// is strictly preferable to leaking the previous account's cached mail forward.
extension AppState {

    // MARK: - Account-scoped purge

    /// Purges the active account's local mail artifacts. Legacy call sites/tests use
    /// this for the currently connected mailbox; saved-account removal passes an
    /// explicit account so inactive accounts do not wipe active-account records.
    func purgeLocalMailArtifacts() throws {
        guard let account = normalizedConnectedAccountEmail else { return }
        try purgeLocalMailArtifacts(for: account, includeUnscopedArtifacts: true)
    }

    /// Purges every local mail artifact when there is no selected mailbox to scope
    /// the erase, while preserving non-mail account settings and credentials.
    func purgeAllLocalMailArtifacts() throws {
        invalidateLocalDataOperations()
        let draftsToRemove = pendingDrafts
        try persistence.purgeAllMailArtifacts()
        for draft in draftsToRemove {
            notifier.removeNotification(identity: draft.identity)
        }
        resetInMemoryAccountArtifacts()
        logger.info("Purged all local mail artifacts")
    }

    /// Purges one account's local mail artifacts from disk and memory. Throws when
    /// persistence cannot durably write the filtered stores so callers can surface
    /// that the privacy erase did not complete.
    func purgeLocalMailArtifacts(
        for accountEmail: String,
        includeUnscopedArtifacts: Bool
    ) throws {
        let account = SavedMailAccount.normalizedEmail(accountEmail)
        guard !account.isEmpty else { return }
        if includeUnscopedArtifacts {
            invalidateLocalDataOperations()
        }
        try persistence.purgeAccountScopedArtifacts(
            for: account,
            includeUnscopedArtifacts: includeUnscopedArtifacts
        )
        resetInMemoryAccountArtifacts(for: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
        logger.info("Purged local mail artifacts for account")
    }

    func ensureLocalDataNotErased(since generation: UInt64) throws {
        guard localDataEraseGeneration == generation else {
            throw DraftDispatchError.accountChanged
        }
    }

    @discardableResult
    func invalidateLocalDataOperations() -> UInt64 {
        localDataEraseGeneration &+= 1
        return localDataEraseGeneration
    }

    func isCurrentLocalDataGeneration(_ generation: UInt64) -> Bool {
        localDataEraseGeneration == generation
    }

    /// Clears the published/in-memory mirrors of the account-scoped stores so the UI
    /// reflects the purge immediately, without waiting for a relaunch to reload from
    /// the (now-empty) files.
    func resetInMemoryAccountArtifacts() {
        cancelAllSendCountdowns()

        voiceProfile = nil
        processedMessages = ProcessedMessages()

        pendingDrafts = []
        pendingDraftCount = 0
        approvingDraftIDs = []
        pendingStaleWarnings = [:]
        pendingDraftUncommittedEditIDs = []
        pendingDraftUncommittedEditBodies = [:]
        pendingDraftUncommittedEditRecipients = [:]
        pendingDraftInvalidRecipientEditIDs = []
        offlineQueuedDispatch = [:]
        draftsWaitingForNetwork = []

        skippedMessages = []
        skippedMessageIDs = []
        skippedMessageReasonsByID = [:]

        activityEvents = []
        draftFeedbackRecords = []
        denyReasonPrompt = nil
        lastUsedDenyReason = nil
        denyReasonPromptSuppressedThisSession = false
    }

    /// Clears in-memory state belonging to a single account while preserving other
    /// saved accounts' queued records. Legacy records with no account are cleared
    /// only when purging the active account.
    func resetInMemoryAccountArtifacts(
        for accountEmail: String,
        includeUnscopedArtifacts: Bool
    ) {
        let account = SavedMailAccount.normalizedEmail(accountEmail)
        guard !account.isEmpty else { return }

        let removedDrafts = pendingDrafts.filter {
            Self.draft($0, belongsTo: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
        }
        let removedIdentities = Set(removedDrafts.map(\.identity))
        for draft in removedDrafts {
            notifier.removeNotification(identity: draft.identity)
        }
        cancelSendCountdowns(for: removedIdentities)

        if includeUnscopedArtifacts {
            voiceProfile = nil
            denyReasonPrompt = nil
            lastUsedDenyReason = nil
            denyReasonPromptSuppressedThisSession = false
        } else if let prompt = denyReasonPrompt,
                  Self.draft(prompt.draft, belongsTo: account, includeUnscopedArtifacts: false) {
            denyReasonPrompt = nil
        }

        processedMessages.removeAccount(account)
        pendingDrafts.removeAll {
            Self.draft($0, belongsTo: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
        }
        pendingDraftCount = pendingDrafts.count

        approvingDraftIDs.subtract(removedIdentities)
        pendingStaleWarnings = pendingStaleWarnings.filter { !removedIdentities.contains($0.key) }
        pendingDraftUncommittedEditIDs.subtract(removedIdentities)
        pendingDraftUncommittedEditBodies = pendingDraftUncommittedEditBodies.filter {
            !removedIdentities.contains($0.key)
        }
        pendingDraftUncommittedEditRecipients = pendingDraftUncommittedEditRecipients.filter {
            !removedIdentities.contains($0.key)
        }
        pendingDraftInvalidRecipientEditIDs.subtract(removedIdentities)
        offlineQueuedDispatch = offlineQueuedDispatch.filter { !removedIdentities.contains($0.key) }
        draftsWaitingForNetwork.subtract(removedIdentities)

        skippedMessages.removeAll { SavedMailAccount.normalizedEmail($0.account) == account }
        skippedMessageIDs = Set(skippedMessages.map(\.id))
        skippedMessageReasonsByID = skippedMessages.reduce(into: [:]) { reasons, message in
            reasons[message.id] = message.reason
        }

        activityEvents.removeAll {
            Self.activity($0, belongsTo: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
        }
        draftFeedbackRecords.removeAll {
            Self.feedback($0, belongsTo: account, includeUnscopedArtifacts: includeUnscopedArtifacts)
        }
    }

    // MARK: - Full erase

    /// Erases every locally persisted store and every per-account Keychain secret,
    /// then resets the running app to a coherent first-run state. Backs the Settings
    /// "Erase all local data" action, which is gated behind a typed `DELETE`
    /// confirmation in the UI (item 96). Returns errors for any local file or
    /// Keychain wipe failure so the caller can keep the sheet open and surface the
    /// partial erase.
    @discardableResult
    func eraseAllLocalData() async -> LocalDataEraseResult {
        invalidateLocalDataOperations()
        for draft in pendingDrafts {
            notifier.removeNotification(identity: draft.identity)
        }
        stopWatching()
        stopAllBackgroundWatchers()
        stopTranscriptFolderWatching()

        await managedAccount.cancelSignIn()
        do {
            try await managedAccount.signOut()
        } catch {
            logger.error("Managed sign-out before erase-all reported an error: \(error.localizedDescription)")
        }

        let persistenceError: String?
        do {
            try persistence.eraseAllLocalData()
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            logger.error("Failed to erase local data directory: \(error.localizedDescription)")
        }

        let keychainError: String?
        do {
            try secrets.removeAll()
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
            logger.error("Failed to clear Keychain during erase-all: \(error.localizedDescription)")
        }

        clearUserDefaultsBackedStores()
        resetInMemoryAccountArtifacts()
        resetInMemoryAccountIdentity()
        let preferenceError = resetInMemoryPreferences()
        resetMessagePreviewForAccountChange(clearSkippedMessages: false)
        clearTransientErrorState()

        let result = LocalDataEraseResult(
            persistenceError: persistenceError,
            keychainError: keychainError,
            preferenceError: preferenceError
        )
        logger.info("Erased all local data (succeeded=\(result.succeeded, privacy: .public))")
        return result
    }

    /// Resets the mail + managed-account identity to a signed-out, disconnected
    /// first-run state.
    private func resetInMemoryAccountIdentity() {
        mailEmail = ""
        mailAppPassword = ""
        mailHost = Settings.default.mailHost
        mailPort = Settings.default.mailPort
        savedAccounts = []
        backgroundConnectedAccounts = []
        isAccountConnected = false
        mailHostExplicitlyEditedEmail = nil
        mailHostExplicitlyEditedBeforeEmail = false

        managedAccountEmail = ""
        managedAccountID = ""
        isManagedSignedIn = false
        managedSignInStage = .idle
        managedEmailInput = ""
        managedCodeInput = ""
        pendingManagedSignInEmail = nil
        managedAccountStatus = nil
        managedAccountStatusFreshUntil = nil
        managedQuota = nil
        didDeleteManagedAccount = false

        // Parked 2026-09-16 (item 100): managed is the only shipped provider, so an
        // erase resets to it (Settings.default.llmProvider is already "managed").
        let defaultProvider = LLMProviderKind(rawValue: Settings.default.llmProvider) ?? .managed
        llmProviderKind = defaultProvider
        llmModel = Settings.default.llmModel
        llmBaseURL = Settings.default.llmBaseURL
        llmAPIKey = ""
        verifiedLLMModel = Settings.default.llmVerifiedModel
        isLLMConnected = false
        isOpenRouterProvisioning = false
        pendingOpenRouterProvisioningMessageSurface = .shared
    }

    /// Resets user preferences to their shipped defaults, including the onboarding
    /// flag so the app presents its first-run experience again.
    private func resetInMemoryPreferences() -> String? {
        pollIntervalSeconds = Settings.default.pollIntervalSeconds
        sendBehavior = SendBehavior(rawValue: Settings.default.sendBehavior) ?? .default
        sendDelaySeconds = Settings.default.sendDelaySeconds
        signaturePolicy = SignaturePolicy(rawValue: Settings.default.signaturePolicy) ?? .default
        signatureText = Settings.default.signatureText
        senderAllowlist = Settings.default.senderAllowlist
        senderBlocklist = Settings.default.senderBlocklist
        verboseDiagnosticLogging = Settings.default.verboseDiagnosticLogging
        let disabledLaunchAtLogin = setLaunchAtLogin(false)
        transcriptWatchedFolderEnabled = Settings.default.transcriptWatchedFolderEnabled
        transcriptWatchedFolderPath = Settings.default.transcriptWatchedFolderPath
        transcriptWatchedFolderSeenSnapshots = nil
        hasRunPreGateDraftSweep = false
        onboardingCompleted = false
        return disabledLaunchAtLogin ? nil : "Launch at login could not be disabled."
    }

    /// Clears surfaced errors/preview state so no stale message survives the wipe.
    private func clearTransientErrorState() {
        connectionError = nil
        connectionErrorIsAppWide = false
        draftError = nil
        approvalError = nil
        watchError = nil
        llmError = nil
        managedError = nil
        voiceError = nil
        transcriptFolderError = nil
    }

    private func clearUserDefaultsBackedStores() {
        subscriptionCacheStore.clearAll()
        usageAlertStore.clearAll()
        googleOAuthInterestStore.clearAll()
        cachedSubscriptionSnapshot = nil
        googleOAuthInterestRegistered = false
        isRegisteringGoogleOAuthInterest = false
    }

    private func cancelSendCountdowns(for identities: Set<String>) {
        guard !identities.isEmpty else { return }
        for identity in identities {
            sendCountdownTasks.removeValue(forKey: identity)?.cancel()
            pendingSendCountdowns.removeValue(forKey: identity)
            sendCountdownNotificationApprovalIDs.remove(identity)
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
