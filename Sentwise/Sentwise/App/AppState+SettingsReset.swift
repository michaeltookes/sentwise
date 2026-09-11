import Foundation

extension AppState {
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
    /// (`transcriptFolderError`). Standing provider/account conditions are
    /// recomputed on the next action, so clearing their inline text here is
    /// cosmetic.
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
        connectionError = nil
        fetchError = nil

        // AI provider / managed-account panes.
        llmError = nil
        managedError = nil
        voiceError = nil
        googleOAuthInterestError = nil

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

    private func resetSettingsBillingAndPlanMessages() {
        manageBillingOperationGeneration &+= 1
        isManagingBilling = false
        manageBillingMessage = nil
        planChangeMessage = nil
        planChangeConfirmationTier = nil
        planChangeFailed = false
    }
}
