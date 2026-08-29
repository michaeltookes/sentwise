import XCTest
import UserNotifications
import SentwiseMail
@testable import Sentwise

/// Tests for notification action sets (item 13). A flagged "needs input" draft
/// must not offer an Approve action, or a notification tap could auto-send a
/// reply that was never written.
@MainActor
final class NotificationServiceTests: XCTestCase {

    private func pendingDraft() -> Draft {
        Draft(
            id: 7,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: "INBOX",
            sourceSubject: "Lunch?",
            sourceFrom: nil,
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: Lunch?",
            body: "Thursday works!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func recipientlessFollowUp() -> Draft {
        Draft(
            id: 8,
            sourceUIDValidity: nil,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: nil,
            sourceSubject: "Post-call follow-up",
            sourceFrom: nil,
            sourceReplyTo: nil,
            sourceMessageID: nil,
            incomingBody: "Marcus: ship Friday.",
            replySubject: "Post-call follow-up",
            body: "Thanks for the call.",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            authoredRecipients: []
        )
    }

    private func notReplyWorthyDraft(body: String = "") -> Draft {
        Draft(
            id: 9,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: "INBOX",
            sourceSubject: "Receipt",
            sourceFrom: MailAddress(name: "Billing", email: "billing@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<receipt@example.com>",
            incomingBody: "Your receipt is attached.",
            replySubject: "Re: Receipt",
            body: body,
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_002),
            notReplyWorthy: DraftNotReplyWorthy(summary: "This receipt does not need a reply.")
        )
    }

    /// A draft whose subject is an RFC 2047 encoded-word — the shape an inbound
    /// IMAP subject with non-ASCII characters actually arrives in.
    private func encodedSubjectDraft() -> Draft {
        var draft = pendingDraft()
        // "Café ☕" as a base64 UTF-8 encoded-word.
        let encoded = Data("Café ☕".utf8).base64EncodedString()
        draft.sourceSubject = "=?UTF-8?B?\(encoded)?="
        return draft
    }

    func testNotificationSubtitleDecodesEncodedWordSubject() {
        let content = UserNotificationService.notificationContent(for: encodedSubjectDraft())
        XCTAssertEqual(content.subtitle, "Café ☕", "banner subtitle must show the decoded subject")
    }

    func testAuthoredNotificationSubtitleDoesNotDecodeUserSubject() {
        var draft = recipientlessFollowUp()
        draft.replySubject = "☕ =?UTF-8?Q?failed?="
        let content = UserNotificationService.notificationContent(for: draft)

        XCTAssertEqual(content.subtitle, "☕ =?UTF-8?Q?failed?=")
    }

    // MARK: - Open / Close alert (item 79)

    func testNotificationOffersOnlyOpenAndCloseActions() {
        let actions = UserNotificationService.openCloseActions()
        let identifiers = actions.map(\.identifier)

        XCTAssertEqual(identifiers, [
            UserNotificationService.openActionIdentifier,
            UserNotificationService.closeActionIdentifier
        ])
        // No approve/deny/destructive action exists on the banner any more.
        XCTAssertFalse(actions.contains { $0.options.contains(.destructive) })
    }

    func testOpenActionBringsAppToForeground() throws {
        let open = try XCTUnwrap(
            UserNotificationService.openCloseActions()
                .first { $0.identifier == UserNotificationService.openActionIdentifier }
        )
        XCTAssertEqual(open.title, "Open")
        XCTAssertTrue(open.options.contains(.foreground))
    }

    func testPrepareNotificationDeliveryRegistersDraftAndUsageCategories() throws {
        let center = FakeUserNotificationCenter()
        let service = UserNotificationService(center: center)

        service.prepareNotificationDelivery()

        XCTAssertTrue(center.delegate === service)
        // The draft-ready category (item 79) plus the usage-alert category (56b).
        XCTAssertEqual(center.categories.count, 2)
        let draft = try XCTUnwrap(
            center.categories.first { $0.identifier == UserNotificationService.categoryIdentifier }
        )
        XCTAssertEqual(draft.actions.map(\.identifier), [
            UserNotificationService.openActionIdentifier,
            UserNotificationService.closeActionIdentifier
        ])
        let usage = try XCTUnwrap(
            center.categories.first { $0.identifier == UserNotificationService.usageCategoryIdentifier }
        )
        XCTAssertEqual(usage.actions.map(\.identifier), [
            UserNotificationService.openUsageActionIdentifier
        ])
    }

    func testRequestAuthorizationPreparesNotificationDelivery() async {
        let center = FakeUserNotificationCenter()
        let service = UserNotificationService(center: center)

        await service.requestAuthorization()

        XCTAssertTrue(center.delegate === service)
        XCTAssertEqual(center.authorizationRequestCount, 1)
        // Draft-ready + usage-alert categories (item 56b).
        XCTAssertEqual(center.categories.count, 2)
    }

    func testEveryDraftVariantUsesTheOpenCloseCategory() {
        for draft in [pendingDraft(), notReplyWorthyDraft(), recipientlessFollowUp()] {
            let content = UserNotificationService.notificationContent(for: draft)
            XCTAssertEqual(content.categoryIdentifier, UserNotificationService.categoryIdentifier)
        }
    }

    func testNotReplyWorthyNotificationShowsSummaryPreview() {
        let content = UserNotificationService.notificationContent(for: notReplyWorthyDraft())

        XCTAssertEqual(content.categoryIdentifier, UserNotificationService.categoryIdentifier)
        XCTAssertEqual(content.title, "No reply needed for Billing")
        XCTAssertEqual(content.body, "This receipt does not need a reply.")
    }

    func testReadyNotificationBodyIsPreviewOnlyWithNoApprovalCopy() {
        let content = UserNotificationService.notificationContent(
            for: notReplyWorthyDraft(body: "Thanks for sending this receipt.")
        )

        XCTAssertEqual(content.categoryIdentifier, UserNotificationService.categoryIdentifier)
        XCTAssertEqual(content.title, "Reply ready for Billing")
        // Body is the preview snippet only — no "Approve sends…" copy (item 79).
        XCTAssertEqual(content.body, "Thanks for sending this receipt.")
        XCTAssertFalse(content.body.contains("Approve"))
    }

    // MARK: - Action routing (item 79)

    func testOpenActionAndBodyTapMapToOpen() {
        XCTAssertEqual(
            UserNotificationService.action(for: UserNotificationService.openActionIdentifier),
            .open
        )
        XCTAssertEqual(
            UserNotificationService.action(for: UNNotificationDefaultActionIdentifier),
            .open
        )
    }

    func testCloseAndDismissActionsAreNoOps() {
        XCTAssertNil(UserNotificationService.action(for: UserNotificationService.closeActionIdentifier))
        XCTAssertNil(UserNotificationService.action(for: UNNotificationDismissActionIdentifier))
    }

    // MARK: - Authorization status (item 78)

    func testCurrentAuthorizationStatusMapsSystemStatus() async {
        let center = FakeUserNotificationCenter()
        let service = UserNotificationService(center: center)

        center.authorizationStatusToReturn = .denied
        let denied = await service.currentAuthorizationStatus()
        XCTAssertEqual(denied, .denied)

        center.authorizationStatusToReturn = .notDetermined
        let notDetermined = await service.currentAuthorizationStatus()
        XCTAssertEqual(notDetermined, .notDetermined)

        center.authorizationStatusToReturn = .provisional
        let provisional = await service.currentAuthorizationStatus()
        XCTAssertEqual(provisional, .authorized, "provisional delivers banners, so it counts as authorized")
    }

    func testRefreshUserInfoSuppressesPresentation() {
        let normal = UserNotificationService.notificationUserInfo(for: pendingDraft())
        XCTAssertFalse(UserNotificationService.suppressesPresentation(userInfo: normal))

        let refresh = UserNotificationService.notificationUserInfo(
            for: pendingDraft(),
            suppressPresentation: true
        )
        XCTAssertTrue(UserNotificationService.suppressesPresentation(userInfo: refresh))
    }

    func testRefreshNotificationContentUsesPassiveDelivery() {
        let normal = UserNotificationService.notificationContent(for: pendingDraft())
        XCTAssertNotEqual(normal.interruptionLevel, .passive)

        let refresh = UserNotificationService.notificationContent(
            for: pendingDraft(),
            suppressPresentation: true
        )
        XCTAssertEqual(refresh.interruptionLevel, .passive)
    }

    func testRefreshNotificationDoesNotCreateNotificationWithoutExistingCenterEntry() async {
        let center = FakeUserNotificationCenter()
        let service = UserNotificationService(center: center)

        service.refreshNotification(for: pendingDraft(), sendBehavior: .autoSend)
        await drainNotificationRefreshTasks()

        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertEqual(center.pendingLookupCount, 1)
        XCTAssertEqual(center.deliveredLookupCount, 1)
    }

    func testRefreshNotificationUpdatesPendingNotificationQuietly() async throws {
        let draft = pendingDraft()
        let center = FakeUserNotificationCenter()
        center.pendingIdentifiers = [draft.identity]
        let service = UserNotificationService(center: center)

        service.refreshNotification(for: draft, sendBehavior: .autoSend)
        await drainNotificationRefreshTasks()

        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(request.identifier, draft.identity)
        XCTAssertTrue(UserNotificationService.suppressesPresentation(userInfo: request.content.userInfo))
        XCTAssertEqual(request.content.interruptionLevel, .passive)
        XCTAssertEqual(center.deliveredLookupCount, 0)
    }

    func testRefreshNotificationUpdatesDeliveredNotificationQuietly() async throws {
        let draft = pendingDraft()
        let center = FakeUserNotificationCenter()
        center.deliveredIdentifiers = [draft.identity]
        let service = UserNotificationService(center: center)

        service.refreshNotification(for: draft, sendBehavior: .saveAsDraft)
        await drainNotificationRefreshTasks()

        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(request.identifier, draft.identity)
        XCTAssertTrue(UserNotificationService.suppressesPresentation(userInfo: request.content.userInfo))
        XCTAssertEqual(request.content.interruptionLevel, .passive)
    }

    func testRemoveNotificationInvalidatesOutstandingRefreshLookup() async throws {
        let draft = pendingDraft()
        let center = FakeUserNotificationCenter()
        var pendingCompletion: ((Set<String>) -> Void)?
        center.pendingLookupHandler = { completion in
            pendingCompletion = completion
        }
        let service = UserNotificationService(center: center)

        service.refreshNotification(for: draft, sendBehavior: .autoSend)
        service.removeNotification(identity: draft.identity)
        try XCTUnwrap(pendingCompletion)([draft.identity])
        await drainNotificationRefreshTasks()

        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertEqual(center.removedDeliveredIdentifiers, [draft.identity])
        XCTAssertEqual(center.removedPendingIdentifiers, [draft.identity])
    }

    func testNotifyUsageAlertPostsUsageCategoryRequest() throws {
        let center = FakeUserNotificationCenter()
        let service = UserNotificationService(center: center)
        let quota = ManagedQuota(
            unit: "drafts", used: 25, limit: 50, remaining: 25,
            resetsAt: ManagedQuotaDate.date(from: "2025-09-01T00:00:00Z")!, enforcement: .soft
        )
        let alert = UsageAlert.make(threshold: .fifty, quota: quota)

        service.notifyUsageAlert(alert)

        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(request.identifier, alert.identifier)
        XCTAssertEqual(request.content.categoryIdentifier, UserNotificationService.usageCategoryIdentifier)
        XCTAssertEqual(request.content.title, alert.title)
        XCTAssertEqual(request.content.body, alert.body)
    }

    private func drainNotificationRefreshTasks() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }
}

private typealias NotificationIdentifierLookupHandler = (@escaping (Set<String>) -> Void) -> Void

private final class FakeUserNotificationCenter: UserNotificationCentering {
    var delegate: UNUserNotificationCenterDelegate?
    var pendingIdentifiers: Set<String> = []
    var deliveredIdentifiers: Set<String> = []
    var authorizationStatusToReturn: UNAuthorizationStatus = .authorized
    var pendingLookupHandler: NotificationIdentifierLookupHandler?
    var deliveredLookupHandler: NotificationIdentifierLookupHandler?
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var pendingLookupCount = 0
    private(set) var deliveredLookupCount = 0
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var removedDeliveredIdentifiers: [String] = []
    private(set) var removedPendingIdentifiers: [String] = []
    private(set) var authorizationRequestCount = 0

    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void) {
        authorizationRequestCount += 1
        completionHandler(true, nil)
    }

    func authorizationStatus(completionHandler: @escaping (UNAuthorizationStatus) -> Void) {
        completionHandler(authorizationStatusToReturn)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request)
        completionHandler?(nil)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIdentifiers.append(contentsOf: identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifiers.append(contentsOf: identifiers)
    }

    func pendingNotificationRequestIdentifiers(completionHandler: @escaping (Set<String>) -> Void) {
        pendingLookupCount += 1
        if let pendingLookupHandler {
            pendingLookupHandler(completionHandler)
        } else {
            completionHandler(pendingIdentifiers)
        }
    }

    func deliveredNotificationIdentifiers(completionHandler: @escaping (Set<String>) -> Void) {
        deliveredLookupCount += 1
        if let deliveredLookupHandler {
            deliveredLookupHandler(completionHandler)
        } else {
            completionHandler(deliveredIdentifiers)
        }
    }
}
