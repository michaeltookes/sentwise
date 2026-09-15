import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "LocalDataPurge")

/// Local-data purge and full erase on `AppState` (backlog item 96 / security
/// finding A-L2). Two operations, both routed through the persistence seam so
/// they are disk-free under the in-memory provider used by Prowl hunts and tests:
///
/// * `purgeLocalMailArtifacts()` deletes the account-scoped, mail-content-bearing
///   files — voice profile, processed-message dedup, pending drafts, recoverable
///   skips, approved-draft tombstones, activity history, and approval-signal
///   feedback — leaving the app-global Settings file (and therefore the app's
///   preferences and any *other* saved account) intact. Offered when the user
///   disconnects, removes a saved account, or deletes their managed account.
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

    /// Purges every account-scoped mail artifact from disk and memory. Safe to call
    /// whether or not an account is connected; it never touches Settings, Keychain,
    /// or another saved account's ability to reconnect.
    func purgeLocalMailArtifacts() {
        // Drop any queued notifications for drafts about to be deleted.
        for draft in pendingDrafts {
            notifier.removeNotification(identity: draft.identity)
        }
        persistence.purgeAccountScopedArtifacts()
        resetInMemoryAccountArtifacts()
        logger.info("Purged local mail artifacts")
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
    }

    // MARK: - Full erase

    /// Erases every locally persisted store and every per-account Keychain secret,
    /// then resets the running app to a coherent first-run state. Backs the Settings
    /// "Erase all local data" action, which is gated behind a typed `DELETE`
    /// confirmation in the UI (item 96). Returns `false` when the Keychain wipe
    /// failed, so the caller can surface it; the on-disk and in-memory wipe still
    /// happened.
    @discardableResult
    func eraseAllLocalData() -> Bool {
        for draft in pendingDrafts {
            notifier.removeNotification(identity: draft.identity)
        }
        stopWatching()

        persistence.eraseAllLocalData()
        var keychainCleared = true
        do {
            try secrets.removeAll()
        } catch {
            keychainCleared = false
            logger.error("Failed to clear Keychain during erase-all: \(error.localizedDescription)")
        }

        resetInMemoryAccountArtifacts()
        resetInMemoryAccountIdentity()
        resetInMemoryPreferences()
        clearTransientErrorState()

        logger.info("Erased all local data (keychainCleared=\(keychainCleared, privacy: .public))")
        return keychainCleared
    }

    /// Resets the mail + managed-account identity to a signed-out, disconnected
    /// first-run state.
    private func resetInMemoryAccountIdentity() {
        mailEmail = ""
        mailAppPassword = ""
        mailHost = Settings.default.mailHost
        mailPort = Settings.default.mailPort
        savedAccounts = []
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

        let defaultProvider = LLMProviderKind(rawValue: Settings.default.llmProvider) ?? .anthropic
        llmProviderKind = defaultProvider
        llmModel = Settings.default.llmModel
        llmBaseURL = Settings.default.llmBaseURL
        llmAPIKey = ""
        verifiedLLMModel = Settings.default.llmVerifiedModel
        isLLMConnected = false
    }

    /// Resets user preferences to their shipped defaults, including the onboarding
    /// flag so the app presents its first-run experience again.
    private func resetInMemoryPreferences() {
        pollIntervalSeconds = Settings.default.pollIntervalSeconds
        sendBehavior = SendBehavior(rawValue: Settings.default.sendBehavior) ?? .default
        sendDelaySeconds = Settings.default.sendDelaySeconds
        signaturePolicy = SignaturePolicy(rawValue: Settings.default.signaturePolicy) ?? .default
        signatureText = Settings.default.signatureText
        senderAllowlist = Settings.default.senderAllowlist
        senderBlocklist = Settings.default.senderBlocklist
        verboseDiagnosticLogging = Settings.default.verboseDiagnosticLogging
        transcriptWatchedFolderEnabled = Settings.default.transcriptWatchedFolderEnabled
        transcriptWatchedFolderPath = Settings.default.transcriptWatchedFolderPath
        transcriptWatchedFolderSeenSnapshots = nil
        hasRunPreGateDraftSweep = false
        onboardingCompleted = false
    }

    /// Clears surfaced errors/preview state so no stale message survives the wipe.
    private func clearTransientErrorState() {
        recentMessages = []
        connectionError = nil
        connectionErrorIsAppWide = false
        fetchError = nil
        bodyError = nil
        draftError = nil
        approvalError = nil
        watchError = nil
        llmError = nil
        managedError = nil
        voiceError = nil
        transcriptFolderError = nil
    }
}
