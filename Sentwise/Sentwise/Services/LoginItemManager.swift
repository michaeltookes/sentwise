import AppKit
import Foundation
import os
import ServiceManagement

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "LoginItem")

/// Manages the app's "launch at login" registration via `SMAppService`.
///
/// `SMAppService.mainApp` registers the running app as a login item without
/// a separate helper bundle. Registration can fail in development (e.g. when
/// running an unsigned build outside `/Applications`), and can succeed while
/// macOS keeps the item disabled (`.requiresApproval`, item 113); the resulting
/// status is logged after every register/unregister and surfaced through
/// `state`.
final class LoginItemManager {

    static let shared = LoginItemManager()

    private init() {}

    /// The current user-facing launch-at-login state.
    var state: LaunchAtLoginState {
        LaunchAtLoginState(status: SMAppService.mainApp.status)
    }

    /// Whether the app is currently registered and approved to launch at login.
    var isEnabled: Bool {
        state == .enabled
    }

    /// Registers or unregisters the app as a login item.
    /// - Returns: `true` if the operation succeeded.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        let succeeded: Bool
        do {
            let status = SMAppService.mainApp.status
            if enabled {
                if status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if status == .enabled || status == .requiresApproval {
                // A `.requiresApproval` item is still registered; unregister it
                // so turning the toggle off actually clears it.
                try SMAppService.mainApp.unregister()
            }
            succeeded = true
        } catch {
            logger.error("Failed to set launch-at-login to \(enabled): \(error.localizedDescription)")
            succeeded = false
        }
        let action = enabled ? "register" : "unregister"
        logger.info("Launch-at-login \(action, privacy: .public) finished; SMAppService status: \(self.state.logName, privacy: .public)")
        return succeeded
    }

    /// Opens System Settings → General → Login Items.
    func openLoginItemsSettings() {
        NSWorkspace.shared.open(LaunchAtLoginState.loginItemsSettingsURL)
    }
}
