import Foundation

extension AppState {
    /// Whether the launch-at-login toggle renders as on (`.enabled` or
    /// `.requiresApproval`, item 113).
    var launchAtLogin: Bool {
        launchAtLoginState.isToggleOn
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        let succeeded = setLaunchAtLoginHandler(enabled)
        refreshLaunchAtLoginState()
        return succeeded
    }

    /// Re-reads the authoritative `SMAppService` status, e.g. after the user
    /// returns from System Settings → Login Items.
    func refreshLaunchAtLoginState() {
        let state = launchAtLoginStatusProvider()
        if state != launchAtLoginState {
            launchAtLoginState = state
        }
    }

    /// Opens System Settings → Login Items so the user can approve Sentwise.
    func openLoginItemsSettings() {
        openLoginItemsSettingsHandler()
    }
}
