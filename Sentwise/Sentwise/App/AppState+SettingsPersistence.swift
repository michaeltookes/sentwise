import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "SettingsPersistence")

/// Builds and persists the `Settings` snapshot from `AppState`'s live published
/// values. Kept in its own file so `AppState` stays within lint limits.
extension AppState {

    /// Persists settings automatically when a tracked preference changes, and
    /// mirrors the verbose-logging preference into the global `DiagnosticLog`
    /// flag (both at launch and on change). Called once from `AppState.init`.
    func setupAutoSave() {
        DiagnosticLog.isVerbose = verboseDiagnosticLogging
        DiagnosticLog.verbose("Verbose diagnostic logging restored from settings")

        $pollIntervalSeconds
            .dropFirst()
            .sink { [weak self] _ in
                self?.saveSettingsAfterPublishedSet(rescheduleInboxWatcher: true)
            }
            .store(in: &cancellables)

        $sendBehavior
            .dropFirst()
            .sink { [weak self] _ in self?.saveSettingsAfterPublishedSet() }
            .store(in: &cancellables)

        $sendDelaySeconds
            .dropFirst()
            .sink { [weak self] _ in self?.saveSettingsAfterPublishedSet() }
            .store(in: &cancellables)

        $verboseDiagnosticLogging
            .dropFirst()
            .sink { [weak self] isVerbose in
                DiagnosticLog.isVerbose = isVerbose
                DiagnosticLog.verbose("Verbose diagnostic logging enabled")
                self?.saveSettingsAfterPublishedSet()
            }
            .store(in: &cancellables)

        $signaturePolicy
            .dropFirst()
            .sink { [weak self] _ in self?.saveSettingsAfterPublishedSet() }
            .store(in: &cancellables)

        $signatureText
            .dropFirst()
            .sink { [weak self] _ in self?.saveSettingsAfterPublishedSet() }
            .store(in: &cancellables)

        $llmModel
            .dropFirst()
            .sink { [weak self] model in
                self?.resetDraftPreviewForLLMChange()
                self?.refreshLLMConnectionStatus(llmModel: model)
                self?.saveSettings(llmModel: model)
            }
            .store(in: &cancellables)
    }

    /// Builds a `Settings` snapshot from the current published values.
    /// Internal so the `AppState+Onboarding` extension can persist the
    /// onboarding flag through the same path.
    func buildSettings(
        mailEmail: String? = nil,
        mailHost: String? = nil,
        mailPort: Int? = nil,
        llmModelOverride: String? = nil,
        signaturePolicyOverride: String? = nil,
        signatureTextOverride: String? = nil
    ) -> Settings {
        Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: pollIntervalSeconds,
            mailEmail: (mailEmail ?? self.mailEmail).trimmingCharacters(in: .whitespacesAndNewlines),
            mailHost: (mailHost ?? self.mailHost).trimmingCharacters(in: .whitespacesAndNewlines),
            mailHostGuidanceEmail: mailHostExplicitlyEditedEmail,
            mailHostGuidancePendingEmail: mailHostExplicitlyEditedBeforeEmail,
            mailPort: mailPort ?? self.mailPort,
            savedAccounts: savedAccounts,
            llmProvider: llmProviderKind.rawValue,
            llmModel: (llmModelOverride ?? self.llmModel).trimmingCharacters(in: .whitespacesAndNewlines),
            llmBaseURL: llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            llmVerifiedModel: verifiedLLMModel,
            managedAccountEmail: managedAccountEmail,
            signaturePolicy: signaturePolicyOverride ?? signaturePolicy.rawValue,
            signatureText: signatureTextOverride ?? signatureText,
            sendBehavior: sendBehavior.rawValue,
            sendDelaySeconds: sendDelaySeconds,
            onboardingCompleted: onboardingCompleted,
            senderAllowlist: senderAllowlist,
            senderBlocklist: senderBlocklist,
            verboseDiagnosticLogging: verboseDiagnosticLogging,
            transcriptWatchedFolderEnabled: transcriptWatchedFolderEnabled,
            transcriptWatchedFolderPath: transcriptWatchedFolderPath,
            transcriptWatchedFolderSeenSnapshots: transcriptWatchedFolderSeenSnapshots,
            hasRunPreGateDraftSweep: hasRunPreGateDraftSweep
        )
    }

    /// Saves settings to disk (debounced).
    func saveSettings(llmModel: String? = nil) {
        let settings = buildSettings(llmModelOverride: llmModel)
        settingsDebouncer.debounce { [weak self] in
            self?.persistence.saveSettings(settings)
        }
    }

    /// `@Published` emits from `willSet`, so defer generic settings snapshots
    /// until the published storage contains the emitted value.
    func saveSettingsAfterPublishedSet(rescheduleInboxWatcher: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            saveSettings()
            if rescheduleInboxWatcher {
                inboxWatcher.reschedule()
            }
        }
    }

    /// Saves a specific settings snapshot immediately, cancelling stale
    /// debounced snapshots first.
    func persistSettingsSync(_ settings: Settings) throws {
        settingsDebouncer.cancel()
        try persistence.saveSettingsSync(settings)
    }

    /// Saves settings immediately (used on app termination).
    func saveSettingsSync() {
        let settings = buildSettings()
        do {
            try persistSettingsSync(settings)
        } catch {
            connectionError = Self.settingsMessage(action: "save", error: error)
            logger.error("Failed to save settings synchronously: \(error.localizedDescription)")
        }
    }

    /// Applies the persisted draft-production preferences (signature policy/text
    /// and send behavior/delay) loaded at launch, plus the one-time pre-gate
    /// draft-sweep flag (item 80). Called from `init` before `setupAutoSave()`
    /// wires the change sinks, so seeding these values does not trigger a spurious
    /// save. Kept here so `AppState.init` stays within the function-body length
    /// limit. Seeding `hasRunPreGateDraftSweep` from settings is essential: without
    /// it `buildSettings` would persist the default `false` and un-set the flag,
    /// making the sweep re-run on every launch.
    func restoreDraftPreferences(from settings: Settings) {
        signaturePolicy = SignaturePolicy(rawValue: settings.signaturePolicy) ?? .default
        signatureText = settings.signatureText
        sendBehavior = SendBehavior(rawValue: settings.sendBehavior) ?? .default
        sendDelaySeconds = settings.sendDelaySeconds
        hasRunPreGateDraftSweep = settings.hasRunPreGateDraftSweep
    }

    /// Restores persisted review/history state after launch fields are seeded.
    func restoreReviewPersistenceState() {
        activityEvents = persistence.loadActivityEvents()
        restoreSkippedMessagesFromPersistence()
    }

    /// Restores skipped-message state at launch, including the lookup maps used
    /// to suppress duplicate skip work within the current session.
    func restoreSkippedMessagesFromPersistence() {
        skippedMessages = Self.restoredSkippedMessages(
            persistence: persistence,
            processedMessages: processedMessages,
            limit: skippedMessageLogLimit
        )
        skippedMessageIDs = Set(skippedMessages.map(\.id))
        skippedMessageReasonsByID = skippedMessages.reduce(into: [:]) { reasons, entry in
            reasons[entry.id] = entry.reason
        }
    }

    /// Restores pending drafts at launch, dropping any already-approved ones and
    /// rebuilding the offline-dispatch bookkeeping. Extracted from `AppState.init`
    /// to keep that initializer and `AppState.swift` within the lint limits.
    static func restoredPendingDraftState(
        persistence: PersistenceProvider
    ) -> (
        drafts: [Draft],
        offlineQueuedDispatch: [String: OfflineQueuedDraftDispatch],
        waitingForNetwork: Set<String>
    ) {
        let approvedDraftIdentities = persistence.loadApprovedDraftIdentities()
        let loadedPendingDrafts = persistence.loadPendingDrafts()
        let pendingDrafts = loadedPendingDrafts.filter { !approvedDraftIdentities.contains($0.identity) }
        if pendingDrafts.count != loadedPendingDrafts.count {
            do {
                try persistence.savePendingDraftsSync(pendingDrafts)
            } catch {
                logger.error("Failed to clean approved pending drafts on launch: \(error.localizedDescription)")
            }
        }
        let offlineQueuedDispatch = offlineQueuedDispatches(from: pendingDrafts)
        return (pendingDrafts, offlineQueuedDispatch, Set(offlineQueuedDispatch.keys))
    }

    /// Restores the visible skip log and drops entries that were already dismissed
    /// into the durable processed-message set. Sweep-created skips are retained
    /// because their source messages were processed before the pending drafts were
    /// later promoted to recoverable skipped entries.
    static func restoredSkippedMessages(
        persistence: PersistenceProvider,
        processedMessages: ProcessedMessages,
        limit: Int
    ) -> [SkippedMessage] {
        let loadedMessages = persistence.loadSkippedMessages()
        let activeMessages = loadedMessages.filter { entry in
            entry.preservesRecoveryWhenProcessed
                || !processedMessages.contains(entry.message, account: entry.account, mailbox: entry.mailbox)
        }
        let boundedMessages = Array(activeMessages.prefix(limit))
        if boundedMessages.count != loadedMessages.count {
            do {
                try persistence.saveSkippedMessagesSync(boundedMessages)
            } catch {
                logger.error("Failed to clean skipped messages on launch: \(error.localizedDescription)")
            }
        }
        return boundedMessages
    }
}
