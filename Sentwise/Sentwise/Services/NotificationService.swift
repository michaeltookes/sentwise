import Foundation
import os
import UserNotifications

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "Notifications")

/// `userInfo` key carrying a draft's `identity` on its notification.
private let draftIdentityUserInfoKey = "draftIdentity"
/// `userInfo` key used when replacing notification copy without a new alert.
private let suppressPresentationUserInfoKey = "suppressPresentation"

protocol UserNotificationCentering: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }

    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void)
    func authorizationStatus(completionHandler: @escaping (UNAuthorizationStatus) -> Void)
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func pendingNotificationRequestIdentifiers(completionHandler: @escaping (Set<String>) -> Void)
    func deliveredNotificationIdentifiers(completionHandler: @escaping (Set<String>) -> Void)
}

final class SystemUserNotificationCenter: UserNotificationCentering {
    private let center: UNUserNotificationCenter

    var delegate: UNUserNotificationCenterDelegate? {
        get { center.delegate }
        set { center.delegate = newValue }
    }

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void) {
        center.requestAuthorization(options: options, completionHandler: completionHandler)
    }

    func authorizationStatus(completionHandler: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { completionHandler($0.authorizationStatus) }
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        center.add(request, withCompletionHandler: completionHandler)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingNotificationRequestIdentifiers(completionHandler: @escaping (Set<String>) -> Void) {
        center.getPendingNotificationRequests { requests in
            let identifiers = Set(requests.map(\.identifier))
            Task { @MainActor in completionHandler(identifiers) }
        }
    }

    func deliveredNotificationIdentifiers(completionHandler: @escaping (Set<String>) -> Void) {
        center.getDeliveredNotifications { notifications in
            let identifiers = Set(notifications.map(\.request.identifier))
            Task { @MainActor in completionHandler(identifiers) }
        }
    }
}

/// An action routed back into the approval queue.
///
/// Since the 2026-08-25 rework (item 79) the draft notification itself only ever
/// yields `.open` — its banner can't show the full reply, so approving from it
/// would be a blind approve. The `.approve` / `.deny` cases remain for in-app and
/// programmatic approval paths (the Review Drafts window's buttons, and a future
/// Slack peer channel — item 30), which act on the full, visible draft.
enum DraftNotificationAction: Equatable {
    /// Approve using the given send behavior (in-app / programmatic path).
    case approve(SendBehavior)
    /// Deny (discard the draft) — in-app / programmatic path.
    case deny
    /// Open the Review Drafts window (the only action the notification produces).
    case open
}

/// The app's view of the system notification-authorization status (item 78),
/// collapsed to the three states the UI reacts to. `provisional`/`ephemeral`
/// (and any future case) count as `authorized` since banners can still appear.
enum NotificationPermission: Equatable {
    case authorized
    case denied
    case notDetermined

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        default: self = .authorized
        }
    }
}

/// Posts native notifications when a draft is ready and routes the user's action
/// back to the app. Injectable so `AppState` can be tested without the real
/// `UNUserNotificationCenter`.
@MainActor
protocol DraftNotifying: AnyObject {
    /// Called on the main actor when the user acts on a notification; the second
    /// argument is the draft's `identity`. The notification response is not
    /// completed until this async handler returns.
    var onAction: ((DraftNotificationAction, String) async -> Void)? { get set }

    /// Requests notification authorization (no-op if already decided).
    func requestAuthorization()

    /// Reads the current system authorization status (item 78), so the app can
    /// surface a hint when notifications are off.
    func currentAuthorizationStatus() async -> NotificationPermission

    /// Posts a notification announcing `draft`. `sendBehavior` is retained for
    /// call-site symmetry with the approval flow but no longer changes the
    /// banner (item 79): every draft notification is an Open / Close alert.
    func notify(for draft: Draft, sendBehavior: SendBehavior)

    /// Replaces the notification copy for `draft` without showing a new banner.
    func refreshNotification(for draft: Draft, sendBehavior: SendBehavior)

    /// Removes any delivered/pending notification for the given draft identity.
    func removeNotification(identity: String)
}

/// A no-op notifier used as the default (and in tests) so constructing an
/// `AppState` never touches `UNUserNotificationCenter`. The real app injects
/// `UserNotificationService` via the app delegate.
@MainActor
final class NullDraftNotifier: DraftNotifying {
    var onAction: ((DraftNotificationAction, String) async -> Void)?
    nonisolated init() {}
    func requestAuthorization() {}
    func currentAuthorizationStatus() async -> NotificationPermission { .authorized }
    func notify(for draft: Draft, sendBehavior: SendBehavior) {}
    func refreshNotification(for draft: Draft, sendBehavior: SendBehavior) {}
    func removeNotification(identity: String) {}
}

/// `DraftNotifying` backed by `UNUserNotificationCenter`.
///
/// Registers a single "draft ready" category whose only actions are **Open**
/// (surface the Review Drafts window to read and approve the full draft) and
/// **Close** (dismiss, no side effects) — item 79. Tapping the body also
/// triggers `.open`. The center is only touched from `requestAuthorization()`
/// onward, so unit tests that never call it stay off the notification system
/// entirely.
@MainActor
final class UserNotificationService: NSObject, DraftNotifying {

    var onAction: ((DraftNotificationAction, String) async -> Void)?

    private let center: UserNotificationCentering
    private var notificationRefreshGenerations: [String: Int] = [:]

    /// The single category carried by every draft notification (item 79). All
    /// approval now happens in the app, so the banner needs only Open / Close.
    static let categoryIdentifier = "DRAFT_READY"
    static let openActionIdentifier = "OPEN_DRAFT"
    static let closeActionIdentifier = "CLOSE_DRAFT"

    init(center: UserNotificationCentering = SystemUserNotificationCenter()) {
        self.center = center
        super.init()
    }

    func requestAuthorization() {
        center.delegate = self
        registerCategory()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription)")
            } else {
                logger.info("Notification authorization granted: \(granted)")
            }
        }
    }

    func currentAuthorizationStatus() async -> NotificationPermission {
        await withCheckedContinuation { continuation in
            center.authorizationStatus { status in
                continuation.resume(returning: NotificationPermission(status))
            }
        }
    }

    func notify(for draft: Draft, sendBehavior: SendBehavior) {
        advanceNotificationRefreshGeneration(identity: draft.identity)
        postNotification(for: draft, suppressPresentation: false)
    }

    func refreshNotification(for draft: Draft, sendBehavior: SendBehavior) {
        let center = center
        let generation = advanceNotificationRefreshGeneration(identity: draft.identity)
        center.pendingNotificationRequestIdentifiers { [weak self] pendingIdentifiers in
            Task { @MainActor in
                guard let self,
                      self.isCurrentNotificationRefreshGeneration(generation, identity: draft.identity) else { return }
                if pendingIdentifiers.contains(draft.identity) {
                    self.postNotification(for: draft, suppressPresentation: true)
                    return
                }
                center.deliveredNotificationIdentifiers { [weak self] deliveredIdentifiers in
                    Task { @MainActor in
                        guard let self,
                              deliveredIdentifiers.contains(draft.identity),
                              self.isCurrentNotificationRefreshGeneration(generation, identity: draft.identity) else {
                            return
                        }
                        self.postNotification(for: draft, suppressPresentation: true)
                    }
                }
            }
        }
    }

    private func postNotification(
        for draft: Draft,
        suppressPresentation: Bool
    ) {
        let content = Self.notificationContent(
            for: draft,
            suppressPresentation: suppressPresentation
        )
        let request = UNNotificationRequest(
            identifier: draft.identity,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                logger.error("Failed to post draft notification: \(error.localizedDescription)")
            }
        }
    }

    func removeNotification(identity: String) {
        advanceNotificationRefreshGeneration(identity: identity)
        center.removeDeliveredNotifications(withIdentifiers: [identity])
        center.removePendingNotificationRequests(withIdentifiers: [identity])
    }

    // MARK: - Helpers

    static func notificationContent(
        for draft: Draft,
        suppressPresentation: Bool = false
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if draft.isAuthored {
            Self.applyAuthoredFollowUpContent(to: content, draft: draft)
        } else {
            Self.applyReplyContent(to: content, draft: draft)
        }
        // Every draft notification is an Open / Close alert now (item 79).
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = Self.notificationUserInfo(
            for: draft,
            suppressPresentation: suppressPresentation
        )
        content.threadIdentifier = draft.sourceAccountEmail ?? "Sentwise"
        if suppressPresentation {
            content.interruptionLevel = .passive
        }
        return content
    }

    /// Banner copy for a reply to an incoming message. The body is a preview only
    /// — approval happens in the app after reading the full draft (item 79).
    private static func applyReplyContent(
        to content: UNMutableNotificationContent,
        draft: Draft
    ) {
        let sender = draft.sourceFrom?.name ?? draft.sourceFrom?.email ?? "someone"
        // Decode RFC 2047 encoded-word subjects so the banner reads the subject,
        // not `=?UTF-8?Q?…`. Display-only; the stored draft is untouched.
        let subject = MIMEEncodedWord.decode(draft.sourceSubject)
        content.subtitle = subject
        if let needsInfo = draft.needsInfo {
            content.title = "Reply to \(sender) needs your input"
            content.body = snippet(needsInfo.summary)
        } else if draft.isFlagged, let notReplyWorthy = draft.notReplyWorthy {
            content.title = "No reply needed for \(sender)"
            content.body = snippet(notReplyWorthy.summary)
        } else {
            content.title = "Reply ready for \(sender)"
            content.body = notificationBody(replyBody: draft.body)
        }
    }

    /// Banner copy for an authored post-call follow-up (item 51).
    private static func applyAuthoredFollowUpContent(
        to content: UNMutableNotificationContent,
        draft: Draft
    ) {
        let subject = draft.replySubject.isEmpty
            ? "Post-call follow-up"
            : draft.replySubject
        content.subtitle = subject
        guard draft.hasAuthoredRecipients else {
            content.title = "Follow-up drafted — add recipients"
            content.body = "Open to choose who this goes to."
            return
        }
        let first = draft.authoredRecipients?.first
        let recipient = first?.name ?? first?.email ?? "your contact"
        content.title = "Follow-up ready for \(recipient)"
        content.body = notificationBody(replyBody: draft.body)
    }

    @discardableResult
    private func advanceNotificationRefreshGeneration(identity: String) -> Int {
        let generation = (notificationRefreshGenerations[identity] ?? 0) + 1
        notificationRefreshGenerations[identity] = generation
        return generation
    }

    private func isCurrentNotificationRefreshGeneration(_ generation: Int, identity: String) -> Bool {
        notificationRefreshGenerations[identity] == generation
    }

    /// The notification's two actions (item 79): **Open** brings the app forward
    /// and opens Review Drafts; **Close** just dismisses, with no side effects.
    /// Neither is destructive — dismissing a banner never discards a draft.
    static func openCloseActions() -> [UNNotificationAction] {
        let open = UNNotificationAction(
            identifier: Self.openActionIdentifier,
            title: "Open",
            options: [.foreground]
        )
        let close = UNNotificationAction(
            identifier: Self.closeActionIdentifier,
            title: "Close",
            options: []
        )
        return [open, close]
    }

    private func registerCategory() {
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: Self.openCloseActions(),
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// A single-line preview of the reply body for the notification.
    static func snippet(_ body: String, maxChars: Int = 140) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > maxChars ? String(collapsed.prefix(maxChars)) + "…" : collapsed
    }

    /// The banner body: a bounded preview of the reply, inviting the user to open
    /// the app to read and approve the full draft (item 79).
    static func notificationBody(replyBody: String) -> String {
        snippet(replyBody)
    }

    static func notificationUserInfo(
        for draft: Draft,
        suppressPresentation: Bool = false
    ) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            draftIdentityUserInfoKey: draft.identity
        ]
        if suppressPresentation {
            userInfo[suppressPresentationUserInfoKey] = true
        }
        return userInfo
    }

    nonisolated static func suppressesPresentation(userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[suppressPresentationUserInfoKey] as? Bool == true
    }

    /// Maps a notification action identifier to the queue action to route, or
    /// `nil` for actions with no side effect (Close and the system dismiss). Only
    /// Open — and a body tap (`UNNotificationDefaultActionIdentifier`) — opens the
    /// app; there is no approve/deny from the banner any more (item 79).
    static func action(for actionIdentifier: String) -> DraftNotificationAction? {
        switch actionIdentifier {
        case Self.openActionIdentifier, UNNotificationDefaultActionIdentifier:
            return .open
        default:
            // Close action and UNNotificationDismissActionIdentifier: no-op.
            return nil
        }
    }
}

extension UserNotificationService: UNUserNotificationCenterDelegate {

    /// Show banners even while the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if Self.suppressesPresentation(userInfo: notification.request.content.userInfo) {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identity = response.notification.request.content.userInfo[draftIdentityUserInfoKey] as? String
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard let identity, let action = Self.action(for: actionIdentifier) else { return }
            await onAction?(action, identity)
        }
    }
}
