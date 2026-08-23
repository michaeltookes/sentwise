import Foundation
import os
import UserNotifications

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "Notifications")

/// `userInfo` key carrying a draft's `identity` on its notification.
private let draftIdentityUserInfoKey = "draftIdentity"
/// `userInfo` key carrying the send behavior displayed on the notification.
private let draftSendBehaviorUserInfoKey = "sendBehavior"
/// `userInfo` key used when replacing notification copy without a new alert.
private let suppressPresentationUserInfoKey = "suppressPresentation"

protocol UserNotificationCentering: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }

    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void)
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

/// An action the user took on a draft-ready notification.
enum DraftNotificationAction: Equatable {
    /// Approve inline using the send behavior displayed on the notification.
    case approve(SendBehavior)
    /// Deny inline (discard the draft).
    case deny
    /// Open the review window (the notification body was clicked).
    case open
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

    /// Posts a notification announcing `draft`; `sendBehavior` tailors the copy.
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
    func notify(for draft: Draft, sendBehavior: SendBehavior) {}
    func refreshNotification(for draft: Draft, sendBehavior: SendBehavior) {}
    func removeNotification(identity: String) {}
}

/// `DraftNotifying` backed by `UNUserNotificationCenter`.
///
/// Registers a "draft ready" category with inline **Approve** and **Deny**
/// actions; tapping the body triggers `.open`. The center is only touched from
/// `requestAuthorization()` onward, so unit tests that never call it stay off
/// the notification system entirely.
@MainActor
final class UserNotificationService: NSObject, DraftNotifying {

    var onAction: ((DraftNotificationAction, String) async -> Void)?

    private let center: UserNotificationCentering
    private var notificationRefreshGenerations: [String: Int] = [:]

    static let categoryIdentifier = "DRAFT_READY"
    /// Category for a flagged "needs input" draft — Deny only, no Approve, since
    /// there is nothing safe to send (item 13).
    static let needsInputCategoryIdentifier = "DRAFT_NEEDS_INPUT"
    /// Category for authored follow-ups that still need recipients. It deliberately
    /// has no inline actions: dismissing the banner must not discard the draft.
    static let recipientNeededCategoryIdentifier = "DRAFT_NEEDS_RECIPIENTS"
    static let approveActionIdentifier = "APPROVE_DRAFT"
    static let denyActionIdentifier = "DENY_DRAFT"

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

    func notify(for draft: Draft, sendBehavior: SendBehavior) {
        advanceNotificationRefreshGeneration(identity: draft.identity)
        postNotification(for: draft, sendBehavior: sendBehavior, suppressPresentation: false)
    }

    func refreshNotification(for draft: Draft, sendBehavior: SendBehavior) {
        let center = center
        let generation = advanceNotificationRefreshGeneration(identity: draft.identity)
        center.pendingNotificationRequestIdentifiers { [weak self] pendingIdentifiers in
            Task { @MainActor in
                guard let self,
                      self.isCurrentNotificationRefreshGeneration(generation, identity: draft.identity) else { return }
                if pendingIdentifiers.contains(draft.identity) {
                    self.postNotification(for: draft, sendBehavior: sendBehavior, suppressPresentation: true)
                    return
                }
                center.deliveredNotificationIdentifiers { [weak self] deliveredIdentifiers in
                    Task { @MainActor in
                        guard let self,
                              deliveredIdentifiers.contains(draft.identity),
                              self.isCurrentNotificationRefreshGeneration(generation, identity: draft.identity) else {
                            return
                        }
                        self.postNotification(for: draft, sendBehavior: sendBehavior, suppressPresentation: true)
                    }
                }
            }
        }
    }

    private func postNotification(
        for draft: Draft,
        sendBehavior: SendBehavior,
        suppressPresentation: Bool
    ) {
        let content = Self.notificationContent(
            for: draft,
            sendBehavior: sendBehavior,
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
        sendBehavior: SendBehavior,
        suppressPresentation: Bool = false
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if draft.isAuthored {
            Self.applyAuthoredFollowUpContent(to: content, draft: draft, sendBehavior: sendBehavior)
        } else {
            Self.applyReplyContent(to: content, draft: draft, sendBehavior: sendBehavior)
        }
        content.userInfo = Self.notificationUserInfo(
            for: draft,
            sendBehavior: sendBehavior,
            suppressPresentation: suppressPresentation
        )
        content.threadIdentifier = draft.sourceAccountEmail ?? "Sentwise"
        if suppressPresentation {
            content.interruptionLevel = .passive
        }
        return content
    }

    /// Banner copy for a reply to an incoming message.
    private static func applyReplyContent(
        to content: UNMutableNotificationContent,
        draft: Draft,
        sendBehavior: SendBehavior
    ) {
        let sender = draft.sourceFrom?.name ?? draft.sourceFrom?.email ?? "someone"
        // Decode RFC 2047 encoded-word subjects so the banner reads the subject,
        // not `=?UTF-8?Q?…`. Display-only; the stored draft is untouched.
        let subject = MIMEEncodedWord.decode(draft.sourceSubject)
        if let needsInfo = draft.needsInfo {
            content.title = "Reply to \(sender) needs your input"
            content.subtitle = subject
            content.body = snippet(needsInfo.summary)
            content.categoryIdentifier = needsInputCategoryIdentifier
        } else if draft.isFlagged, let notReplyWorthy = draft.notReplyWorthy {
            content.title = "No reply needed for \(sender)"
            content.subtitle = subject
            content.body = snippet(notReplyWorthy.summary)
            content.categoryIdentifier = needsInputCategoryIdentifier
        } else {
            content.title = "Reply ready for \(sender)"
            content.subtitle = subject
            content.body = notificationBody(replyBody: draft.body, sendBehavior: sendBehavior)
            content.categoryIdentifier = categoryIdentifier(for: sendBehavior)
        }
    }

    /// Banner copy for an authored post-call follow-up (item 51). A follow-up with
    /// no recipients yet uses an open-only category, so dismissing the banner cannot
    /// discard the draft.
    private static func applyAuthoredFollowUpContent(
        to content: UNMutableNotificationContent,
        draft: Draft,
        sendBehavior: SendBehavior
    ) {
        let subject = draft.replySubject.isEmpty
            ? "Post-call follow-up"
            : MIMEEncodedWord.decode(draft.replySubject)
        guard draft.hasAuthoredRecipients else {
            content.title = "Follow-up drafted — add recipients"
            content.subtitle = subject
            content.body = "Open review to choose who this goes to."
            content.categoryIdentifier = recipientNeededCategoryIdentifier
            return
        }
        let first = draft.authoredRecipients?.first
        let recipient = first?.name ?? first?.email ?? "your contact"
        content.title = "Follow-up ready for \(recipient)"
        content.subtitle = subject
        content.body = notificationBody(replyBody: draft.body, sendBehavior: sendBehavior)
        content.categoryIdentifier = categoryIdentifier(for: sendBehavior)
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

    static func categoryIdentifier(for sendBehavior: SendBehavior) -> String {
        switch sendBehavior {
        case .autoSend:
            return "\(categoryIdentifier)_AUTO_SEND"
        case .saveAsDraft:
            return "\(categoryIdentifier)_SAVE_DRAFT"
        }
    }

    static func approveActionTitle(for sendBehavior: SendBehavior) -> String {
        switch sendBehavior {
        case .autoSend:
            return "Send Now"
        case .saveAsDraft:
            return "Save Draft"
        }
    }

    static func approvalNotice(for sendBehavior: SendBehavior) -> String {
        switch sendBehavior {
        case .autoSend:
            return "Approve sends this reply now"
        case .saveAsDraft:
            return "Approve saves this as a draft"
        }
    }

    static func draftActions(for sendBehavior: SendBehavior = .default) -> [UNNotificationAction] {
        let approve = UNNotificationAction(
            identifier: Self.approveActionIdentifier,
            title: Self.approveActionTitle(for: sendBehavior),
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: Self.denyActionIdentifier,
            title: "Deny",
            options: [.authenticationRequired, .destructive]
        )
        return [approve, deny]
    }

    /// The Deny-only action set for a flagged draft — no Approve, since it must
    /// not be sent (item 13).
    static func needsInputActions() -> [UNNotificationAction] {
        [UNNotificationAction(
            identifier: Self.denyActionIdentifier,
            title: "Dismiss",
            options: [.authenticationRequired, .destructive]
        )]
    }

    static func recipientNeededActions() -> [UNNotificationAction] {
        []
    }

    private func registerCategory() {
        var categories = Set(SendBehavior.allCases.map { sendBehavior in
            UNNotificationCategory(
                identifier: Self.categoryIdentifier(for: sendBehavior),
                actions: Self.draftActions(for: sendBehavior),
                intentIdentifiers: [],
                options: []
            )
        })
        categories.insert(UNNotificationCategory(
            identifier: Self.needsInputCategoryIdentifier,
            actions: Self.needsInputActions(),
            intentIdentifiers: [],
            options: []
        ))
        categories.insert(UNNotificationCategory(
            identifier: Self.recipientNeededCategoryIdentifier,
            actions: Self.recipientNeededActions(),
            intentIdentifiers: [],
            options: []
        ))
        center.setNotificationCategories(categories)
    }

    /// A single-line preview of the reply body for the notification.
    static func snippet(_ body: String, maxChars: Int = 140) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > maxChars ? String(collapsed.prefix(maxChars)) + "…" : collapsed
    }

    static func notificationBody(replyBody: String, sendBehavior: SendBehavior) -> String {
        "\(approvalNotice(for: sendBehavior)). \(snippet(replyBody))"
    }

    static func notificationUserInfo(
        for draft: Draft,
        sendBehavior: SendBehavior,
        suppressPresentation: Bool = false
    ) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            draftIdentityUserInfoKey: draft.identity,
            draftSendBehaviorUserInfoKey: sendBehavior.rawValue
        ]
        if suppressPresentation {
            userInfo[suppressPresentationUserInfoKey] = true
        }
        return userInfo
    }

    nonisolated static func suppressesPresentation(userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[suppressPresentationUserInfoKey] as? Bool == true
    }

    static func action(for actionIdentifier: String, userInfo: [AnyHashable: Any]) -> DraftNotificationAction {
        switch actionIdentifier {
        case Self.approveActionIdentifier:
            guard let rawSendBehavior = userInfo[draftSendBehaviorUserInfoKey] as? String,
                  let sendBehavior = SendBehavior(rawValue: rawSendBehavior) else {
                return .open
            }
            return .approve(sendBehavior)
        case Self.denyActionIdentifier:
            return .deny
        default:
            // UNNotificationDefaultActionIdentifier (body tap) and dismiss.
            return .open
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
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard actionIdentifier != UNNotificationDismissActionIdentifier,
                  let identity else { return }
            await onAction?(Self.action(for: actionIdentifier, userInfo: userInfo), identity)
        }
    }
}
