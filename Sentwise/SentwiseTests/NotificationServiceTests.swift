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
        let content = UserNotificationService.notificationContent(
            for: encodedSubjectDraft(),
            sendBehavior: .autoSend
        )
        XCTAssertEqual(content.subtitle, "Café ☕", "banner subtitle must show the decoded subject")
    }

    func testFlaggedNotificationOffersNoApproveAction() {
        let actions = UserNotificationService.needsInputActions()
        XCTAssertFalse(
            actions.contains { $0.identifier == UserNotificationService.approveActionIdentifier },
            "a needs-input notification must never offer Approve"
        )
        XCTAssertTrue(actions.contains { $0.identifier == UserNotificationService.denyActionIdentifier })
    }

    func testReadyDraftNotificationStillOffersApprove() {
        let actions = UserNotificationService.draftActions(for: .autoSend)
        XCTAssertTrue(actions.contains { $0.identifier == UserNotificationService.approveActionIdentifier })
    }

    func testNotReplyWorthyNotificationOffersNoApproveAction() {
        let content = UserNotificationService.notificationContent(
            for: notReplyWorthyDraft(),
            sendBehavior: .autoSend
        )

        XCTAssertEqual(content.categoryIdentifier, UserNotificationService.needsInputCategoryIdentifier)
        XCTAssertEqual(content.title, "No reply needed for Billing")
        XCTAssertEqual(content.body, "This receipt does not need a reply.")
    }

    func testEditedNotReplyWorthyNotificationOffersApproveAction() {
        let content = UserNotificationService.notificationContent(
            for: notReplyWorthyDraft(body: "Thanks for sending this receipt."),
            sendBehavior: .autoSend
        )

        XCTAssertEqual(content.categoryIdentifier, UserNotificationService.categoryIdentifier(for: .autoSend))
        XCTAssertEqual(content.title, "Reply ready for Billing")
        XCTAssertEqual(content.body, "Approve sends this reply now. Thanks for sending this receipt.")
    }

    func testRecipientlessFollowUpNotificationHasNoDestructiveActions() {
        let content = UserNotificationService.notificationContent(
            for: recipientlessFollowUp(),
            sendBehavior: .autoSend
        )
        let actions = UserNotificationService.recipientNeededActions()

        XCTAssertEqual(content.categoryIdentifier, UserNotificationService.recipientNeededCategoryIdentifier)
        XCTAssertTrue(actions.isEmpty)
    }

    func testRefreshUserInfoSuppressesPresentation() {
        let normal = UserNotificationService.notificationUserInfo(
            for: pendingDraft(),
            sendBehavior: .autoSend
        )
        XCTAssertFalse(UserNotificationService.suppressesPresentation(userInfo: normal))

        let refresh = UserNotificationService.notificationUserInfo(
            for: pendingDraft(),
            sendBehavior: .autoSend,
            suppressPresentation: true
        )
        XCTAssertTrue(UserNotificationService.suppressesPresentation(userInfo: refresh))
    }

    func testRefreshNotificationContentUsesPassiveDelivery() {
        let normal = UserNotificationService.notificationContent(
            for: pendingDraft(),
            sendBehavior: .autoSend
        )
        XCTAssertNotEqual(normal.interruptionLevel, .passive)

        let refresh = UserNotificationService.notificationContent(
            for: pendingDraft(),
            sendBehavior: .autoSend,
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
    var pendingLookupHandler: NotificationIdentifierLookupHandler?
    var deliveredLookupHandler: NotificationIdentifierLookupHandler?
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var pendingLookupCount = 0
    private(set) var deliveredLookupCount = 0
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var removedDeliveredIdentifiers: [String] = []
    private(set) var removedPendingIdentifiers: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void) {
        completionHandler(true, nil)
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
