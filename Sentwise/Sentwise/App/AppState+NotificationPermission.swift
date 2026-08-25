import AppKit
import Foundation

/// Notification-permission surfacing (item 78).
///
/// When macOS "Allow Notifications" is off, posted draft notifications are
/// silently dropped — and since item 79 the notification is the app's primary
/// nudge to open and approve a draft. So the app checks the live authorization
/// status and, while it is off, shows a non-nagging hint (in the menu and the
/// Review Drafts window) with a deep link into System Settings. The hint clears
/// itself the moment the status is granted, because every surface re-checks.
extension AppState {

    /// Deep link to System Settings → Notifications → Sentwise.
    static let notificationSettingsURLString =
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.tookes.Sentwise"

    /// Whether notifications are currently unavailable — denied outright, or not
    /// yet decided. Drives the "notifications are off" hint.
    var notificationsBlocked: Bool {
        notificationPermission != .authorized
    }

    /// Re-reads the live authorization status and updates `notificationPermission`.
    /// While the status is `.notDetermined` it also (re-)requests authorization,
    /// since macOS only shows the prompt while undecided; once denied, the OS will
    /// not re-prompt and the user must go to System Settings.
    func refreshNotificationPermission() async {
        let permission = await notifier.currentAuthorizationStatus()
        if permission == .notDetermined {
            await notifier.requestAuthorization()
            notificationPermission = await notifier.currentAuthorizationStatus()
        } else {
            notificationPermission = permission
        }
    }

    /// Opens System Settings → Notifications → Sentwise so the user can turn
    /// notifications back on.
    func openNotificationSystemSettings() {
        guard let url = URL(string: Self.notificationSettingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }
}
