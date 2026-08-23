import SentwiseMail
import XCTest
@testable import Sentwise

// swiftlint:disable file_length type_body_length

/// Tests for the auto-send safety net / undo window (item 23): the cancellable
/// countdown between approving an auto-send draft and the actual dispatch.
@MainActor
final class AppStateSendCountdownTests: XCTestCase {

    private func pendingDraft(
        id: UInt32 = 1,
        subject: String = "Lunch?",
        body: String = "Thursday works!",
        notReplyWorthy: DraftNotReplyWorthy? = nil
    ) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: subject,
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: \(subject)",
            body: body,
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            notReplyWorthy: notReplyWorthy
        )
    }

    private func authoredDraft(id: UInt32 = 2, recipients: [MailAddress]) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: nil,
            sourceAccountEmail: "me@gmail.com",
            sourceSubject: "Follow-up: Sync",
            sourceFrom: recipients.first,
            sourceReplyTo: nil,
            sourceMessageID: nil,
            incomingBody: "Call transcript.",
            replySubject: "Follow-up: Sync",
            body: "Thanks for the call.",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            authoredRecipients: recipients
        )
    }

    private func makeAppState(
        provider: MailProvider,
        sendDelaySeconds: Int,
        tickNanoseconds: UInt64,
        notifier: DraftNotifying = FakeDraftNotifier(),
        seed drafts: [Draft]
    ) -> AppState {
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
            sendDelaySeconds: sendDelaySeconds
        ), pendingDrafts: drafts)
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: notifier
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        appState.sendCountdownTickNanoseconds = tickNanoseconds
        return appState
    }

    /// Polls until `condition` holds or the timeout elapses, letting the MainActor
    /// countdown task interleave. Fails the test on timeout.
    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000)
            await Task.yield()
        }
    }

    private func decodedBody(from rfc822: Data?) -> String {
        guard let rfc822, let text = String(data: rfc822, encoding: .utf8),
              let separator = text.range(of: "\r\n\r\n") else {
            return ""
        }
        let encoded = text[separator.upperBound...]
            .components(separatedBy: .newlines)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Delay 0 keeps today's instant-send behavior

    func testDelayZeroSendsImmediately() async {
        let draft = pendingDraft()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 0,
            tickNanoseconds: 1_000_000,
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.sendCallCount, 1)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertTrue(appState.pendingSendCountdowns.isEmpty)
    }

    // MARK: - Delay > 0 starts a countdown and defers the send

    func testDelayStartsCountdownWithoutSendingImmediately() async {
        let draft = pendingDraft()
        let provider = FakeAppMailProvider(result: .success(()))
        // A slow tick keeps the window open across the assertions.
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 5,
            tickNanoseconds: 1_000_000_000,
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.pendingSendCountdowns[draft.identity], 5)
        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertFalse(appState.approvingDraftIDs.contains(draft.identity))

        appState.cancelAllSendCountdowns()
    }

    func testCountdownFiresSendAfterWindow() async {
        let draft = pendingDraft()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 2,
            tickNanoseconds: 2_000_000,
            seed: [draft]
        )
        let persistence = appState.persistence as? AppStateMemoryPersistence

        await appState.approveDraft(draft)
        await waitUntil { appState.pendingDrafts.isEmpty }

        XCTAssertEqual(provider.sendCallCount, 1)
        XCTAssertTrue(appState.pendingSendCountdowns.isEmpty)
        XCTAssertTrue(persistence?.loadApprovedDraftIdentities().contains(draft.identity) ?? false)
        XCTAssertEqual(appState.activityEvents.first?.kind, .approvedSent)
    }

    func testCountdownQueuesWhenConnectivityDropsDuringDispatchRetries() async {
        let draft = pendingDraft()
        let provider = FakeAppMailProvider(
            result: .success(()),
            sendResult: .failure(.connectionFailed("offline"))
        )
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 1,
            tickNanoseconds: 1,
            seed: [draft]
        )
        appState.retryRunner = RetryRunner(
            sleep: { _ in
                await MainActor.run { appState.isOnline = false }
            },
            randomUnitInterval: { 0.5 }
        )

        await appState.approveDraft(draft)
        await waitUntil { appState.isWaitingForNetwork(draft.identity) || appState.approvalError != nil }

        XCTAssertEqual(provider.sendCallCount, RetryPolicy.default.maxAttempts)
        XCTAssertTrue(appState.isWaitingForNetwork(draft.identity))
        XCTAssertEqual(
            appState.offlineQueuedDispatch[draft.identity],
            OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        )
        XCTAssertNil(appState.approvalError)
        XCTAssertTrue(appState.activityEvents.contains { $0.kind == .queuedOffline })
    }

    // MARK: - Cancel returns the draft to pending with edits intact

    func testCancelDuringWindowKeepsDraftPendingWithEdits() async {
        let draft = pendingDraft()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 5,
            tickNanoseconds: 1_000_000_000,
            seed: [draft]
        )

        await appState.approvePendingDraft(draft, withEditedBody: "Edited before countdown.")

        XCTAssertEqual(appState.pendingSendCountdowns[draft.identity], 5)
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Edited before countdown.")

        appState.cancelSendCountdown(draft)

        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertTrue(appState.pendingSendCountdowns.isEmpty)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Edited before countdown.")
        XCTAssertEqual(appState.activityEvents.first?.kind, .sendCanceled)
    }

    func testCountdownFlushesRegisteredInlineEditBeforeSending() async {
        let draft = pendingDraft()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 2,
            tickNanoseconds: 2_000_000,
            seed: [draft]
        )

        await appState.approveDraft(draft)
        appState.notePendingDraftBodyEdit(draft, editedBody: "Edited during countdown.")
        await waitUntil { appState.pendingDrafts.isEmpty }

        XCTAssertEqual(provider.sendCallCount, 1)
        XCTAssertEqual(decodedBody(from: provider.sentRFC822), "Edited during countdown.")
        XCTAssertFalse(appState.pendingDraftUncommittedEditIDs.contains(draft.identity))
        XCTAssertNil(appState.pendingDraftUncommittedEditBodies[draft.identity])
    }

    func testCountdownFlushesRegisteredRecipientEditBeforeSending() async {
        let draft = authoredDraft(recipients: [MailAddress(email: "old@example.com")])
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 2,
            tickNanoseconds: 2_000_000,
            seed: [draft]
        )

        await appState.approveDraft(draft)
        appState.notePendingDraftRecipientEdit(
            draft,
            recipients: [MailAddress(email: "new@example.com")]
        )
        await waitUntil { appState.pendingDrafts.isEmpty }

        XCTAssertEqual(provider.sendCallCount, 1)
        XCTAssertEqual(provider.sentEnvelope?.recipients, ["new@example.com"])
        XCTAssertFalse(appState.pendingDraftUncommittedEditIDs.contains(draft.identity))
        XCTAssertNil(appState.pendingDraftUncommittedEditRecipients[draft.identity])
    }

    func testCountdownBlocksWhenRecipientEditClearsAuthoredRecipients() async {
        let draft = authoredDraft(recipients: [MailAddress(email: "old@example.com")])
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 2,
            tickNanoseconds: 2_000_000,
            seed: [draft]
        )
        var openedReview = false
        appState.openReviewHandler = { openedReview = true }

        await appState.approveDraft(draft)
        appState.notePendingDraftRecipientEdit(draft, recipients: [])
        await waitUntil { appState.pendingSendCountdowns.isEmpty }

        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(appState.pendingDrafts.first?.authoredRecipients?.map(\.email), [])
        XCTAssertFalse(appState.pendingDraftUncommittedEditIDs.contains(draft.identity))
        XCTAssertTrue(openedReview)
        XCTAssertNotNil(appState.approvalError)
    }

    func testCountdownBlocksWhenRegisteredInlineEditCannotPersist() async {
        let draft = pendingDraft()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 2,
            tickNanoseconds: 2_000_000,
            seed: [draft]
        )
        let persistence = appState.persistence as? AppStateMemoryPersistence
        var openedReview = false
        appState.openReviewHandler = { openedReview = true }

        await appState.approveDraft(draft)
        persistence?.pendingDraftSaveError = AppStatePersistenceError.writeDenied
        XCTAssertNil(appState.updatePendingDraftBody(draft, to: "Edited during countdown."))
        await waitUntil { appState.pendingSendCountdowns.isEmpty }

        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Thursday works!")
        XCTAssertEqual(appState.pendingDraftUncommittedEditBodies[draft.identity], "Edited during countdown.")
        XCTAssertTrue(appState.pendingDraftUncommittedEditIDs.contains(draft.identity))
        XCTAssertTrue(openedReview)
        XCTAssertNotNil(appState.approvalError)
    }

    func testCountdownBlocksWhenNotReplyWorthyDraftBecomesFlaggedAgain() async {
        let draft = pendingDraft(
            body: "Thanks for the receipt.",
            notReplyWorthy: DraftNotReplyWorthy(summary: "This receipt does not need a reply.")
        )
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 2,
            tickNanoseconds: 2_000_000,
            seed: [draft]
        )
        var openedReview = false
        appState.openReviewHandler = { openedReview = true }

        await appState.approveDraft(draft)
        appState.notePendingDraftBodyEdit(draft, editedBody: "  \n")
        await waitUntil { appState.pendingSendCountdowns.isEmpty }

        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(appState.pendingDrafts.first?.body, "  \n")
        XCTAssertEqual(appState.pendingDrafts.first?.isFlagged, true)
        XCTAssertFalse(appState.pendingDraftUncommittedEditIDs.contains(draft.identity))
        XCTAssertNil(appState.pendingDraftUncommittedEditBodies[draft.identity])
        XCTAssertTrue(openedReview)
        XCTAssertNotNil(appState.approvalError)
    }

    // MARK: - Stale verdict at fire time blocks the send and warns

    func testStaleVerdictAtFireTimeBlocksSendAndSurfacesWarning() async {
        let draft = pendingDraft()
        let provider = SearchStubMailProvider(
            threadResult: MailSearchResult(
                messages: [
                    MailMessage(id: 1, uidValidity: 10, from: MailAddress(email: "alice@example.com"),
                                subject: "Lunch?", date: ""),
                    MailMessage(id: 9, uidValidity: 10, from: MailAddress(email: "alice@example.com"),
                                subject: "Re: Lunch?", date: "")
                ],
                totalMatches: 2,
                offset: 0,
                hasMore: false
            )
        )
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 2,
            tickNanoseconds: 2_000_000,
            seed: [draft]
        )

        await appState.approveDraft(draft)
        await waitUntil { appState.pendingStaleWarnings[draft.identity] != nil }

        XCTAssertEqual(provider.sendCount, 0)
        XCTAssertEqual(appState.pendingStaleWarnings[draft.identity], .newerReplyInThread)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertTrue(appState.pendingSendCountdowns.isEmpty)
    }

    func testNotificationCountdownStaleVerdictOpensReviewWindowAndRepostsNotification() async {
        let draft = pendingDraft()
        let provider = SearchStubMailProvider(
            threadResult: MailSearchResult(
                messages: [
                    MailMessage(id: 1, uidValidity: 10, from: MailAddress(email: "alice@example.com"),
                                subject: "Lunch?", date: ""),
                    MailMessage(id: 9, uidValidity: 10, from: MailAddress(email: "alice@example.com"),
                                subject: "Re: Lunch?", date: "")
                ],
                totalMatches: 2,
                offset: 0,
                hasMore: false
            )
        )
        let notifier = FakeDraftNotifier()
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 2,
            tickNanoseconds: 2_000_000,
            notifier: notifier,
            seed: [draft]
        )
        var openedReview = false
        appState.openReviewHandler = { openedReview = true }

        await notifier.fireAction(.approve(.autoSend), identity: draft.identity)
        await waitUntil { appState.pendingStaleWarnings[draft.identity] != nil }

        XCTAssertEqual(provider.sendCount, 0)
        XCTAssertEqual(appState.pendingStaleWarnings[draft.identity], .newerReplyInThread)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertTrue(appState.pendingSendCountdowns.isEmpty)
        XCTAssertTrue(openedReview)
        XCTAssertEqual(notifier.notifiedDrafts.map(\.identity), [draft.identity])
    }

    // MARK: - A double-approve while counting down never double-sends

    func testDoubleApproveDuringCountdownSendsOnce() async {
        let draft = pendingDraft()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 2,
            tickNanoseconds: 5_000_000,
            seed: [draft]
        )

        await appState.approveDraft(draft)
        // Second approval while the first is still counting down must be ignored.
        await appState.approveDraft(draft)

        XCTAssertEqual(appState.pendingSendCountdowns[draft.identity], 2)
        await waitUntil { appState.pendingDrafts.isEmpty }

        XCTAssertEqual(provider.sendCallCount, 1)
    }

    // MARK: - Notification approvals route through the countdown too

    func testNotificationApproveStartsCountdown() async {
        let draft = pendingDraft()
        let provider = FakeAppMailProvider(result: .success(()))
        let notifier = FakeDraftNotifier()
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
            sendDelaySeconds: 5
        ), pendingDrafts: [draft])
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: notifier
        )
        appState.pendingDrafts = [draft]
        appState.pendingDraftCount = 1
        appState.sendCountdownTickNanoseconds = 1_000_000_000
        var openedReview = false
        appState.openReviewHandler = { openedReview = true }

        await notifier.fireAction(.approve(.autoSend), identity: draft.identity)

        XCTAssertEqual(appState.pendingSendCountdowns[draft.identity], 5)
        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertTrue(openedReview)

        appState.cancelAllSendCountdowns()
    }

    // MARK: - Lifecycle events cancel outstanding countdowns

    func testDisconnectCancelsCountdownWithoutSending() {
        let draft = pendingDraft()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(
            provider: provider,
            sendDelaySeconds: 5,
            tickNanoseconds: 1_000_000_000,
            seed: [draft]
        )

        appState.startSendCountdown(for: draft, credentials: appState.mailCredentials)
        XCTAssertEqual(appState.pendingSendCountdowns[draft.identity], 5)

        appState.disconnectMail()

        XCTAssertTrue(appState.pendingSendCountdowns.isEmpty)
        XCTAssertEqual(provider.sendCallCount, 0)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
    }
}

// swiftlint:enable file_length type_body_length
