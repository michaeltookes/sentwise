import SentwiseMail
import UserNotifications
import XCTest
@testable import Sentwise

@MainActor
private final class NotificationActionProbe {
    var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

@MainActor
final class AppStateApprovalTests: XCTestCase {

    private func pendingDraft(id: UInt32 = 1, sourceAccountEmail: String? = "me@gmail.com") -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: sourceAccountEmail,
            sourceMailbox: "INBOX",
            sourceSubject: "Lunch?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: Lunch?",
            body: "Thursday works!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeAppState(
        sendBehavior: SendBehavior = .autoSend,
        sendResult: Result<Void, MailError> = .success(()),
        appendResult: Result<Void, MailError> = .success(()),
        seed drafts: [Draft] = []
    ) -> (AppState, FakeAppMailProvider, FakeDraftNotifier, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: sendBehavior.rawValue,
            sendDelaySeconds: 0
        ), pendingDrafts: drafts)
        let provider = FakeAppMailProvider(result: .success(()), appendResult: appendResult, sendResult: sendResult)
        let notifier = FakeDraftNotifier()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: notifier
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return (appState, provider, notifier, persistence)
    }

    private func makeAppStateWithSuspendedSend(
        seed drafts: [Draft]
    ) -> (AppState, SuspendedSendMailProvider, FakeDraftNotifier, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue,
            sendDelaySeconds: 0
        ), pendingDrafts: drafts)
        let provider = SuspendedSendMailProvider()
        let notifier = FakeDraftNotifier()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: notifier
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return (appState, provider, notifier, persistence)
    }

    func testApproveActionLabelReflectsSendBehavior() {
        let (autoSend, _, _, _) = makeAppState(sendBehavior: .autoSend)
        XCTAssertEqual(autoSend.approveActionLabel, "Send")
        let (saveAsDraft, _, _, _) = makeAppState(sendBehavior: .saveAsDraft)
        XCTAssertEqual(saveAsDraft.approveActionLabel, "Save to Drafts")
    }

    func testApproveAutoSendSendsRemovesAndClearsNotification() async {
        let draft = pendingDraft()
        let (appState, provider, notifier, persistence) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.sentEnvelope?.recipients, ["alice@example.com"])
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.pendingDraftCount, 0)
        XCTAssertEqual(notifier.removedIdentities, [draft.identity])
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
        XCTAssertTrue(persistence.loadApprovedDraftIdentities().contains(draft.identity))
        XCTAssertNil(appState.approvalError)
        XCTAssertFalse(appState.approvingDraftIDs.contains(draft.identity))
    }

    func testApproveSaveAsDraftAppendsInsteadOfSending() async {
        let draft = pendingDraft()
        let (appState, provider, _, _) = makeAppState(sendBehavior: .saveAsDraft, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.appendedMailbox, .drafts)
        XCTAssertNil(provider.sentRFC822)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testApproveFailureKeepsDraftAndNotification() async {
        let draft = pendingDraft()
        let (appState, _, notifier, persistence) = makeAppState(
            sendBehavior: .autoSend,
            sendResult: .failure(.authenticationFailed("bad app password")),
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(persistence.loadPendingDrafts().map(\.identity), [draft.identity])
        XCTAssertNotNil(appState.approvalError)
        XCTAssertTrue(notifier.removedIdentities.isEmpty)
        XCTAssertFalse(appState.approvingDraftIDs.contains(draft.identity))
    }

    func testApproveUsesTombstoneWhenPendingRemovalPersistenceFails() async {
        let draft = pendingDraft()
        let (appState, provider, notifier, persistence) = makeAppState(sendBehavior: .autoSend, seed: [draft])
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        await appState.approveDraft(draft)

        XCTAssertNotNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.pendingDraftCount, 0)
        XCTAssertEqual(persistence.loadPendingDrafts().map(\.identity), [draft.identity])
        XCTAssertTrue(persistence.loadApprovedDraftIdentities().contains(draft.identity))
        XCTAssertEqual(notifier.removedIdentities, [draft.identity])
        XCTAssertNil(appState.approvalError)
    }

    func testApproveKeepsDraftDurableWhileSendIsInFlight() async {
        let draft = pendingDraft()
        let (appState, provider, notifier, persistence) = makeAppStateWithSuspendedSend(seed: [draft])

        let approval = Task {
            await appState.approveDraft(draft)
        }
        await fulfillment(of: [provider.didStartSend], timeout: 1)
        await Task.yield()

        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(persistence.loadPendingDrafts().map(\.identity), [draft.identity])
        XCTAssertTrue(persistence.loadApprovedDraftIdentities().isEmpty)
        XCTAssertTrue(notifier.removedIdentities.isEmpty)

        provider.completeSend(with: .success(()))
        await approval.value

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
        XCTAssertTrue(persistence.loadApprovedDraftIdentities().contains(draft.identity))
        XCTAssertEqual(notifier.removedIdentities, [draft.identity])
    }

    func testLaunchFiltersApprovedDraftTombstones() {
        let draft = pendingDraft()
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6"
            ),
            pendingDrafts: [draft],
            approvedDraftIdentities: [draft.identity]
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.pendingDraftCount, 0)
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
    }

    func testApproveBlocksDraftFromDifferentAccount() async {
        let draft = pendingDraft(sourceAccountEmail: "old@gmail.com")
        let (appState, provider, notifier, persistence) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(appState.pendingDraftCount, 1)
        XCTAssertEqual(persistence.loadPendingDrafts().map(\.identity), [draft.identity])
        XCTAssertTrue(notifier.removedIdentities.isEmpty)
        XCTAssertEqual(appState.approvalError, "This draft was generated for a different email account.")
    }

    func testApproveBlocksDraftFromOutgoingMailbox() async {
        var draft = pendingDraft()
        draft.sourceMailbox = Mailbox.drafts.imapName
        let (appState, provider, notifier, persistence) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(appState.pendingDraftCount, 1)
        XCTAssertEqual(persistence.loadPendingDrafts().map(\.identity), [draft.identity])
        XCTAssertTrue(notifier.removedIdentities.isEmpty)
        XCTAssertEqual(appState.approvalError, "Draft replies are only available for incoming mail.")
    }

    func testDenyDiscardsWithoutSendingAndClearsNotification() async {
        let draft = pendingDraft()
        let (appState, provider, notifier, persistence) = makeAppState(seed: [draft])

        appState.denyDraft(draft)

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertEqual(notifier.removedIdentities, [draft.identity])
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
    }

    func testOnlyTargetedDraftIsRemoved() async {
        let keep = pendingDraft(id: 1)
        let approve = pendingDraft(id: 2)
        let (appState, _, _, _) = makeAppState(seed: [keep, approve])

        await appState.approveDraft(approve)

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
    }

    // MARK: - Notification routing

    func testNotificationApproveActionApprovesDraft() async {
        let draft = pendingDraft()
        let (appState, provider, notifier, _) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await notifier.fireAction(.approve(.autoSend), identity: draft.identity)

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(provider.sentEnvelope)
    }

    func testNotificationApproveActionUsesDisplayedSendBehavior() async {
        let draft = pendingDraft()
        let (appState, provider, notifier, _) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await notifier.fireAction(.approve(.saveAsDraft), identity: draft.identity)

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(provider.appendedMailbox, .drafts)
        XCTAssertNil(provider.sentRFC822)
    }

    func testNotificationApproveActionWaitsForApprovalToFinish() async {
        let draft = pendingDraft()
        let (appState, provider, _, _) = makeAppStateWithSuspendedSend(seed: [draft])
        let probe = NotificationActionProbe()

        let route = Task {
            await appState.handleNotificationAction(.approve(.autoSend), identity: draft.identity)
            probe.markComplete()
        }
        await fulfillment(of: [provider.didStartSend], timeout: 1)
        await Task.yield()

        XCTAssertFalse(probe.isComplete)
        XCTAssertEqual(provider.sentMessageCount, 1)
        XCTAssertTrue(appState.approvingDraftIDs.contains(draft.identity))

        provider.completeSend(with: .success(()))
        await route.value

        XCTAssertTrue(probe.isComplete)
        XCTAssertFalse(appState.approvingDraftIDs.contains(draft.identity))
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testNotificationDenyActionPresentsReasonPickerAndOpensReview() async {
        // A notification can't host the reason picker, so deny (item 83) routes to
        // the reason-gated flow: the draft stays pending, the picker is presented,
        // and the review window that hosts it is opened.
        let draft = pendingDraft()
        let (appState, _, notifier, _) = makeAppState(seed: [draft])
        var opened = false
        appState.openReviewHandler = { opened = true }

        await notifier.fireAction(.deny, identity: draft.identity)

        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(appState.denyReasonPrompt?.id, draft.identity)
        XCTAssertTrue(opened)
    }

    func testNotificationDenyWithSilencedPickerDiscardsSilently() async {
        // With "don't ask again this session" set, a notification deny reuses the
        // remembered reason and discards immediately (still recorded).
        let draft = pendingDraft()
        let (appState, _, notifier, _) = makeAppState(seed: [draft])
        appState.lastUsedDenyReason = DenyReason(code: .handleLater)
        appState.denyReasonPromptSuppressedThisSession = true

        await notifier.fireAction(.deny, identity: draft.identity)

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNil(appState.denyReasonPrompt)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.denyReason?.code, .handleLater)
    }

    func testNotificationDenyDoesNotReplaceActivePrompt() async {
        let first = pendingDraft(id: 1)
        let second = pendingDraft(id: 2)
        let (appState, _, notifier, _) = makeAppState(seed: [first, second])
        var openCount = 0
        appState.openReviewHandler = { openCount += 1 }
        _ = appState.requestDenyDraft(first)

        await notifier.fireAction(.deny, identity: second.identity)

        XCTAssertEqual(appState.denyReasonPrompt?.id, first.identity)
        XCTAssertTrue(appState.pendingDrafts.contains { $0.identity == second.identity })
        XCTAssertEqual(openCount, 1)
    }

    func testNotificationOpenActionInvokesReviewHandler() async {
        let (appState, _, notifier, _) = makeAppState(seed: [pendingDraft()])
        var opened = false
        appState.openReviewHandler = { opened = true }

        await notifier.fireAction(.open, identity: "anything")

        XCTAssertTrue(opened)
    }

    func testUnknownIdentityActionIsIgnored() async {
        let (appState, _, notifier, _) = makeAppState(seed: [pendingDraft()])

        await notifier.fireAction(.deny, identity: "missing")

        XCTAssertEqual(appState.pendingDrafts.count, 1)
    }

    func testNotificationOffersOnlyOpenAndCloseNoApproval() {
        // The banner can't show the full reply, so it no longer approves/denies
        // — it only opens the app (item 79).
        let identifiers = UserNotificationService.openCloseActions().map(\.identifier)
        XCTAssertEqual(identifiers, [
            UserNotificationService.openActionIdentifier,
            UserNotificationService.closeActionIdentifier
        ])
        XCTAssertEqual(
            UserNotificationService.action(for: UserNotificationService.openActionIdentifier),
            .open
        )
        XCTAssertNil(UserNotificationService.action(for: UserNotificationService.closeActionIdentifier))
    }

    func testNotificationBodyIsPreviewWithNoApprovalCopy() {
        let body = UserNotificationService.notificationBody(replyBody: "Thursday works!")
        XCTAssertEqual(body, "Thursday works!")
        XCTAssertFalse(body.contains("Approve"))
    }

    // MARK: - Enqueue posts a notification (and captures the incoming body)

    func testWatcherEnqueuePostsNotificationWithIncomingBody() async {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        // Seed a completed baseline with a low UID cutoff so message 7 counts as
        // newly arrived (past the cold-start baseline) and gets drafted.
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        processed.setBaselineUID(account: "me@gmail.com", mailbox: .inbox, uid: 1, uidValidity: nil)
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6"
            ),
            processedMessages: processed
        )
        let message = MailMessage(
            id: 7,
            from: MailAddress(name: "Alice", email: "alice@x.com"),
            subject: "Ping",
            date: "",
            messageID: "<7@x.com>"
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: .success([message]),
            bodyResult: .success(Data("Can you review this?".utf8))
        )
        let notifier = FakeDraftNotifier()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "Sure!"))),
            notifier: notifier
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(notifier.notifiedDrafts.map(\.id), [7])
        XCTAssertEqual(appState.pendingDrafts.first?.incomingBody, "Can you review this?")
    }
}
