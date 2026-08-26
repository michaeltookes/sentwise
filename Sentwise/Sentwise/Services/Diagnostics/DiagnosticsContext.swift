import Foundation

/// Non-PII environment context included at the top of a diagnostics bundle
/// (item 36).
///
/// Every field here is deliberately safe to publish: app/OS/hardware versions,
/// the *kind* of LLM provider (never a key), and a handful of behavioural
/// settings. It never carries credentials, the account or mailbox email, the
/// mail host/username, tokens, or the watched-folder path (which would leak the
/// macOS username). The assembled report is additionally run through
/// `DiagnosticsRedactor`, so even an accidental value is scrubbed.
struct DiagnosticsContext: Equatable {

    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let hardwareModel: String
    /// The selected LLM provider *kind* (raw value), e.g. `managed` — never a key.
    let providerKind: String
    let sendBehavior: String
    let pollIntervalSeconds: Int
    let notificationPermission: String
    let verboseLogging: Bool
    /// Whether a transcript folder is being watched — the boolean only, never the
    /// path (the path contains the macOS username).
    let watchedFolderEnabled: Bool

    /// Renders the context as a stable, human-readable `Key: value` block.
    func render() -> String {
        let lines = [
            "App version: \(appVersion) (\(buildNumber))",
            "macOS: \(osVersion)",
            "Hardware: \(hardwareModel)",
            "LLM provider: \(providerKind)",
            "Send behavior: \(sendBehavior)",
            "Poll interval: \(pollIntervalSeconds)s",
            "Notifications: \(notificationPermission)",
            "Verbose logging: \(verboseLogging ? "on" : "off")",
            "Watching transcript folder: \(watchedFolderEnabled ? "yes" : "no")"
        ]
        return lines.joined(separator: "\n")
    }

    /// The macOS version string from `ProcessInfo`, e.g. "14.5.0".
    static func osVersionString(_ processInfo: ProcessInfo = .processInfo) -> String {
        let version = processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The hardware model identifier (e.g. "Mac15,3") via `sysctl`. Returns
    /// "unknown" if the query fails. Not PII — just the machine class.
    static func hardwareModelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: buffer)
    }

    /// The app's marketing version from the bundle, defaulting when absent.
    static func appVersionString(_ bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The app's build number from the bundle, defaulting when absent.
    static func buildNumberString(_ bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
