import Foundation
import UserNotifications

/// The usage-threshold notification path (backlog item 56b), split from the
/// draft-notification core so `NotificationService.swift` stays within length
/// limits. Its Open action routes to Settings → AI Provider (via
/// `onOpenUsageSettings`), a distinct category from the draft-ready one so
/// approval and usage alerts never share routing.
extension UserNotificationService {

    /// The usage-threshold category. Its Open action routes to Settings → AI
    /// Provider rather than Review Drafts.
    static var usageCategoryIdentifier: String { "USAGE_ALERT" }
    static var openUsageActionIdentifier: String { "OPEN_USAGE_SETTINGS" }

    /// The usage alert's single action: **Open** brings the app forward and opens
    /// Settings → AI Provider.
    static func usageAlertActions() -> [UNNotificationAction] {
        [
            UNNotificationAction(
                identifier: Self.openUsageActionIdentifier,
                title: "Open",
                options: [.foreground]
            )
        ]
    }

    func notifyUsageAlert(_ alert: UsageAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.categoryIdentifier = Self.usageCategoryIdentifier
        // Stable per threshold + window so a re-post replaces rather than stacks.
        let request = UNNotificationRequest(
            identifier: alert.identifier,
            content: content,
            trigger: nil
        )
        addUsageAlertRequest(request)
    }
}
