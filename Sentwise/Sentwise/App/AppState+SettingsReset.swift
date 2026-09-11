import Foundation

struct SettingsTransientMessages: Equatable {
    var connectionError: String?
    var workspaceAuthFailure: WorkspaceAuthFailure = .none
    var workspaceAuthFailureAccountID: String?
    var workspaceAuthIsCustomDomain: Bool = false
    var llmError: String?
    var managedError: String?
    var voiceError: String?
    var googleOAuthInterestError: String?
}

extension AppState {
    enum TransientMessageSurface {
        case shared
        case settings
    }

    /// Clears the transient inline messages and errors shown in the Settings
    /// window's panes so each Settings session starts clean.
    ///
    /// Motivation (item 90 follow-up): a plan-change error ("Could not change your
    /// plan.") lingered in the Subscription pane after the window was closed and
    /// reopened, because `AppState` outlives the window. Called when a Settings
    /// session opens and closes.
    ///
    /// Scope is the Settings surface only — it deliberately does not touch the
    /// draft/review or menu-bar flow's own status (e.g. `approvalError`,
    /// `draftSavedMessage`, `draftSentMessage`), mailbox-browser row-action
    /// errors (`bodyError`, `draftError`), or active watched-folder failures
    /// (`transcriptFolderError`). Mailbox/provider/account/voice controls are
    /// shared with the Setup Assistant, so Settings uses a separate transient
    /// message bucket that can be cleared without erasing onboarding feedback.
    func resetTransientSettingsMessages() {
        settingsTransientMessageGeneration &+= 1

        // Recent-message preview belongs to Settings; invalidate a slow fetch so
        // it cannot republish `fetchError` after the pane has gone away.
        _ = nextPreviewGeneration()
        isFetching = false

        // Billing portal fetches are presentation-only. Plan changes are not:
        // they may already be changing the remote subscription, so preserve their
        // operation generation and busy state while clearing only their messages.
        resetSettingsBillingAndPlanMessages()

        // Account / mailbox panes.
        settingsTransientMessages.connectionError = nil
        settingsTransientMessages.workspaceAuthFailure = .none
        settingsTransientMessages.workspaceAuthFailureAccountID = nil
        settingsTransientMessages.workspaceAuthIsCustomDomain = false
        fetchError = nil

        // AI provider / managed-account panes.
        settingsTransientMessages.llmError = nil
        settingsTransientMessages.managedError = nil
        settingsTransientMessages.voiceError = nil
        settingsTransientMessages.googleOAuthInterestError = nil

        // General / signature / diagnostics panes. `transcriptFolderError` is a
        // standing watcher condition; keep it until the watcher restarts or
        // accepts a transcript successfully.
        signatureDetectionMessage = nil
        signatureDetectionSucceeded = nil
        diagnosticsError = nil
    }

    func isCurrentSettingsTransientMessageGeneration(_ generation: UInt64) -> Bool {
        settingsTransientMessageGeneration == generation
    }

    func isCurrentTransientMessageSurface(_ surface: TransientMessageSurface, generation: UInt64) -> Bool {
        surface == .shared || isCurrentSettingsTransientMessageGeneration(generation)
    }

    func connectionError(for surface: TransientMessageSurface) -> String? {
        if surface == .settings {
            return settingsTransientMessages.connectionError ?? connectionError
        }
        return connectionError
    }

    func setConnectionError(_ message: String?, for surface: TransientMessageSurface) {
        if surface == .settings {
            settingsTransientMessages.connectionError = message
        } else {
            connectionError = message
        }
    }

    func llmError(for surface: TransientMessageSurface) -> String? {
        surface == .settings ? settingsTransientMessages.llmError : llmError
    }

    func setLLMError(_ message: String?, for surface: TransientMessageSurface) {
        if surface == .settings {
            settingsTransientMessages.llmError = message
        } else {
            llmError = message
        }
    }

    func managedError(for surface: TransientMessageSurface) -> String? {
        surface == .settings ? settingsTransientMessages.managedError : managedError
    }

    func setManagedError(_ message: String?, for surface: TransientMessageSurface) {
        if surface == .settings {
            settingsTransientMessages.managedError = message
        } else {
            managedError = message
        }
    }

    func voiceError(for surface: TransientMessageSurface) -> String? {
        surface == .settings ? settingsTransientMessages.voiceError : voiceError
    }

    func setVoiceError(_ message: String?, for surface: TransientMessageSurface) {
        if surface == .settings {
            settingsTransientMessages.voiceError = message
        } else {
            voiceError = message
        }
    }

    func googleOAuthInterestError(for surface: TransientMessageSurface) -> String? {
        surface == .settings ? settingsTransientMessages.googleOAuthInterestError : googleOAuthInterestError
    }

    func setGoogleOAuthInterestError(_ message: String?, for surface: TransientMessageSurface) {
        if surface == .settings {
            settingsTransientMessages.googleOAuthInterestError = message
        } else {
            googleOAuthInterestError = message
        }
    }

    private func resetSettingsBillingAndPlanMessages() {
        manageBillingOperationGeneration &+= 1
        isManagingBilling = false
        manageBillingMessage = nil
        planChangeMessage = nil
        planChangeConfirmationTier = nil
        planChangeFailed = false
    }
}
