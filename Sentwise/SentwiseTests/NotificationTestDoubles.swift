import Foundation
@testable import Sentwise

/// Records notification calls and lets tests simulate the user acting on a
/// delivered notification via `onAction`.
@MainActor
final class FakeDraftNotifier: DraftNotifying {
    var onAction: ((DraftNotificationAction, String) async -> Void)?
    private(set) var authorizationRequested = false
    private(set) var notifiedDrafts: [Draft] = []
    private(set) var refreshedDrafts: [Draft] = []
    private(set) var removedIdentities: [String] = []
    /// The status `currentAuthorizationStatus()` reports; tests set this to
    /// simulate notifications being off (item 78).
    var authorizationStatus: NotificationPermission = .authorized
    private(set) var authorizationStatusChecks = 0

    nonisolated init() {}

    func requestAuthorization() { authorizationRequested = true }

    func currentAuthorizationStatus() async -> NotificationPermission {
        authorizationStatusChecks += 1
        return authorizationStatus
    }

    func notify(for draft: Draft, sendBehavior: SendBehavior) {
        notifiedDrafts.append(draft)
    }

    func refreshNotification(for draft: Draft, sendBehavior: SendBehavior) {
        refreshedDrafts.append(draft)
    }

    func removeNotification(identity: String) {
        removedIdentities.append(identity)
    }

    /// Simulates the user acting on the notification for `identity`.
    func fireAction(_ action: DraftNotificationAction, identity: String) async {
        await onAction?(action, identity)
    }
}
