import AppKit
import ServiceManagement

/// The user-facing state of "Launch at login", derived from `SMAppService.Status`
/// (item 113).
///
/// `SMAppService.mainApp.register()` can succeed while macOS keeps the login
/// item disabled (the user once switched Sentwise off in System Settings → Login
/// Items), leaving the status at `.requiresApproval`. Treating that as "off"
/// made the toggle snap back with no explanation, so the Settings toggle and the
/// status-menu item both render this mapping instead of a bare `Bool`.
enum LaunchAtLoginState: Equatable {
    /// Registered and allowed to launch at login.
    case enabled
    /// Registered, but disabled by the user in System Settings → Login Items.
    case requiresApproval
    /// Not registered.
    case notRegistered
    /// macOS could not find the app's login item (e.g. an unsigned build
    /// outside `/Applications`).
    case notFound

    /// System Settings deep link to the Login Items pane.
    static let loginItemsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )!

    /// Caption shown under the toggle (and in the status menu) when macOS has
    /// disabled the login item. QA spec text — keep it verbatim.
    static let requiresApprovalCaption =
        "macOS has disabled Sentwise in Login Items. Turn it back on in System Settings."

    /// Title of the button / menu item that opens the Login Items pane.
    static let openLoginItemsTitle = "Open Login Items…"

    init(status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }

    /// Whether the toggle renders as on. `.requiresApproval` stays on: the user
    /// asked for it and the app is registered; only macOS approval is missing.
    var isToggleOn: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        }
    }

    /// Explanatory caption, or `nil` when the toggle speaks for itself.
    var caption: String? {
        self == .requiresApproval ? Self.requiresApprovalCaption : nil
    }

    /// Whether to offer the "Open Login Items…" action.
    var showsOpenLoginItemsAction: Bool {
        self == .requiresApproval
    }

    /// Check-mark state for the status-menu "Launch at Login" item.
    var menuItemState: NSControl.StateValue {
        isToggleOn ? .on : .off
    }

    /// Stable name for log lines.
    var logName: String {
        switch self {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        }
    }
}
