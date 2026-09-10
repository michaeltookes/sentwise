import Foundation

extension AppState {
    /// Clears the transient inline messages and errors shown in the Settings
    /// window's panes so reopening Settings returns to a clean state.
    ///
    /// Motivation (item 90 follow-up): a plan-change error ("Could not change your
    /// plan.") lingered in the Subscription pane after the window was closed and
    /// reopened, because `AppState` outlives the window. Called from
    /// `SettingsWindowController.windowWillClose`.
    ///
    /// Scope is the Settings surface only — it deliberately does not touch the
    /// draft/review or menu-bar flow's own status (e.g. `approvalError`,
    /// `draftSavedMessage`, `draftSentMessage`). Standing conditions (a mailbox
    /// that is actually disconnected, an unverified provider) are recomputed on
    /// the next action, so clearing their inline text here is cosmetic.
    func resetTransientSettingsMessages() {
        // Plan-management + billing (also cancels any in-flight change/manage ops).
        resetPlanManagementState()

        // Account / mailbox panes.
        connectionError = nil
        fetchError = nil
        bodyError = nil
        draftError = nil

        // AI provider / managed-account panes.
        llmError = nil
        managedError = nil
        voiceError = nil
        googleOAuthInterestError = nil

        // General / signature / diagnostics / transcript panes.
        signatureDetectionMessage = nil
        transcriptFolderError = nil
        diagnosticsError = nil
    }
}
