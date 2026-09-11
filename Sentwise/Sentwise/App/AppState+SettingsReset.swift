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
    var hasUnseenLLMCallbackError = false
    var hasUnseenManagedCallbackError = false
}

extension AppState {
    enum TransientMessageSurface {
        case shared
        case settings

        init?(persistedValue: String) {
            switch persistedValue {
            case "shared":
                self = .shared
            case "settings":
                self = .settings
            default:
                return nil
            }
        }

        var persistedValue: String {
            switch self {
            case .shared:
                return "shared"
            case .settings:
                return "settings"
            }
        }
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
    /// Settings-origin browser callback errors survive until their relevant error
    /// renderer appears, because Settings may open on an unrelated tab first.
    func resetTransientSettingsMessages() {
        settingsTransientMessageGeneration &+= 1
        let hadUnseenLLMCallbackError = settingsTransientMessages.hasUnseenLLMCallbackError
        let hadUnseenManagedCallbackError = settingsTransientMessages.hasUnseenManagedCallbackError
        let preservedLLMError = hadUnseenLLMCallbackError
            ? settingsTransientMessages.llmError
            : nil
        let preservedManagedError = hadUnseenManagedCallbackError
            ? settingsTransientMessages.managedError
            : nil

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
        settingsTransientMessages.llmError = preservedLLMError
        settingsTransientMessages.managedError = preservedManagedError
        settingsTransientMessages.voiceError = nil
        settingsTransientMessages.googleOAuthInterestError = nil
        settingsTransientMessages.hasUnseenLLMCallbackError = hadUnseenLLMCallbackError && preservedLLMError != nil
        settingsTransientMessages.hasUnseenManagedCallbackError =
            hadUnseenManagedCallbackError && preservedManagedError != nil

        // General / signature panes. `transcriptFolderError` is a
        // standing watcher condition; keep it until the watcher restarts or
        // accepts a transcript successfully.
        signatureDetectionMessage = nil
        signatureDetectionSucceeded = nil
    }

    func isCurrentSettingsTransientMessageGeneration(_ generation: UInt64) -> Bool {
        settingsTransientMessageGeneration == generation
    }

    func isCurrentTransientMessageSurface(_ surface: TransientMessageSurface, generation: UInt64) -> Bool {
        surface == .shared || isCurrentSettingsTransientMessageGeneration(generation)
    }

    func connectionError(for surface: TransientMessageSurface) -> String? {
        if surface == .settings {
            if let settingsError = settingsTransientMessages.connectionError {
                return settingsError
            }
            return connectionErrorIsAppWide ? connectionError : nil
        }
        return connectionError
    }

    func setConnectionError(_ message: String?, for surface: TransientMessageSurface) {
        if surface == .settings {
            settingsTransientMessages.connectionError = message
        } else {
            setSharedConnectionError(message, isAppWide: false)
        }
    }

    func setAppWideConnectionError(_ message: String?) {
        setSharedConnectionError(message, isAppWide: true)
    }

    private func setSharedConnectionError(_ message: String?, isAppWide: Bool) {
        connectionError = message
        connectionErrorIsAppWide = message == nil ? false : isAppWide
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

    func markSettingsLLMCallbackErrorPendingDisplay(for surface: TransientMessageSurface) {
        guard surface == .settings else { return }
        settingsTransientMessages.hasUnseenLLMCallbackError = true
    }

    func markSettingsLLMCallbackErrorDisplayed(for surface: TransientMessageSurface) {
        guard surface == .settings else { return }
        settingsTransientMessages.hasUnseenLLMCallbackError = false
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

    func markSettingsManagedCallbackErrorPendingDisplay(for surface: TransientMessageSurface) {
        guard surface == .settings else { return }
        settingsTransientMessages.hasUnseenManagedCallbackError = true
    }

    func markSettingsManagedCallbackErrorDisplayed(for surface: TransientMessageSurface) {
        guard surface == .settings else { return }
        settingsTransientMessages.hasUnseenManagedCallbackError = false
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
