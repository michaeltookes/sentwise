import Foundation
import os
import ServiceManagement

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "LoginItem")

/// Manages the app's "launch at login" registration via `SMAppService`.
///
/// `SMAppService.mainApp` registers the running app as a login item without
/// a separate helper bundle. Registration can fail in development (e.g. when
/// running an unsigned build outside `/Applications`); failures are logged and
/// surfaced by re-reading the authoritative status.
final class LoginItemManager {

    static let shared = LoginItemManager()

    private init() {}

    /// Whether the app is currently registered to launch at login.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item.
    /// - Returns: `true` if the operation succeeded.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            logger.error("Failed to set launch-at-login to \(enabled): \(error.localizedDescription)")
            return false
        }
    }
}
