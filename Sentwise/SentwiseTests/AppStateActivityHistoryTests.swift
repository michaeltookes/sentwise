import SentwiseMail
import XCTest
@testable import Sentwise

/// Tests the activity-history store and its wiring into the draft/skip/approve
/// streams (item 21): events are recorded metadata-only, persisted and bounded,
/// clearable, and linkable back to their source message when the account matches.
@MainActor
final class AppStateActivityHistoryTests: XCTestCase {

    private func message(id: UInt32, from: String = "alice@x.com") -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 7,
            from: MailAddress(name: "Alice", email: from),
            subject: "Subject \(id)",
            date: "",
            messageID: "<\(id)@x.com>"
        )
    }

    private func pendingDraft(id: UInt32 = 1) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailHost: "imap.gmail.com",
            sourceMailPort: 993,
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

    private func baselineProcessed() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        return processed
    }

    private func makeAppState(
        sendBehavior: SendBehavior = .autoSend,
        fetch: Result<[MailMessage], MailError> = .success([]),
        sendResult: Result<Void, MailError> = .success(()),
        appendResult: Result<Void, MailError> = .success(()),
        seed drafts: [Draft] = [],
        processed: ProcessedMessages? = nil
    ) -> (AppState, FakeAppMailProvider, AppStateMemoryPersistence) {
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
                llmVerifiedModel: "claude-sonnet-4-6",
                sendBehavior: sendBehavior.rawValue,
                sendDelaySeconds: 0
            ),
            processedMessages: processed ?? baselineProcessed(),
            pendingDrafts: drafts
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: fetch,
            bodyResult: .success(Data("Please advise.".utf8)),
            appendResult: appendResult,
            sendResult: sendResult
        )
        let llm = FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "On it.")))
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        // Item 27: retry instantly so any transient-failure test doesn't wait on
        // real backoff.
        appState.retryRunner = .immediate
        return (appState, provider, persistence)
    }

    // MARK: - Store mechanics

    func testRecordActivityIsNewestFirstAndBounded() {
        let (appState, _, _) = makeAppState()
        let limit = appState.activityEventLogLimit

        for index in 1...(limit + 5) {
            appState.recordActivity(ActivityEvent(kind: .draftCreated, subject: "S\(index)"))
        }

        XCTAssertEqual(appState.activityEvents.count, limit)
        // Newest first: the last recorded subject is at the front.
        XCTAssertEqual(appState.activityEvents.first?.subject, "S\(limit + 5)")
        XCTAssertEqual(appState.activityEvents.last?.subject, "S6")
    }

    func testClearActivityHistoryEmptiesAndPersists() {
        let (appState, _, persistence) = makeAppState()
        appState.recordActivity(ActivityEvent(kind: .draftCreated, subject: "S1"))
        XCTAssertFalse(appState.activityEvents.isEmpty)

        appState.clearActivityHistory()

        XCTAssertTrue(appState.activityEvents.isEmpty)
        XCTAssertTrue(persistence.loadActivityEvents().isEmpty)
    }

    func testActivityDetailVisibilityIncludesSaveFailuresAndEditNotes() {
        XCTAssertTrue(ActivityEventKind.sendFailed.showsFailureDetail)
        XCTAssertTrue(ActivityEventKind.saveFailed.showsFailureDetail)
        XCTAssertFalse(ActivityEventKind.approvedSaved.showsFailureDetail)
        XCTAssertTrue(ActivityEventKind.approvedSent.showsSuccessDetail)
        XCTAssertTrue(ActivityEventKind.approvedSaved.showsSuccessDetail)
        XCTAssertFalse(ActivityEventKind.saveFailed.showsSuccessDetail)
    }

    func testActivitySubjectDisplayDecodesEncodedWords() {
        let encoded = Data("Café".utf8).base64EncodedString()
        let event = ActivityEvent(kind: .draftCreated, subject: "=?UTF-8?B?\(encoded)?=")

        XCTAssertEqual(event.subjectDisplay, "Café")
    }

    func testActivityAccessibilityLabelIncludesVisibleDetail() {
        let event = ActivityEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .approvedSent,
            sender: "Alice",
            subject: "Lunch?",
            detail: "Edited before send"
        )

        XCTAssertTrue(event.activityHistoryAccessibilityLabel.contains("Edited before send"))
    }

    func testActivityEventsPersistAndReloadOnNewAppState() {
        let (appState, _, persistence) = makeAppState()
        appState.recordActivity(ActivityEvent(kind: .approvedSent, subject: "Persisted"))

        // A fresh AppState over the same persistence reloads the history.
        let secrets = InMemorySecretStore(seed: [.mailAppPassword: "app-pw"])
        let reloaded = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )

        XCTAssertEqual(reloaded.activityEvents.map(\.subject), ["Persisted"])
    }

    // MARK: - Watcher / skip streams

    func testWatcherDraftRecordsDraftCreatedEvent() async {
        let (appState, _, persistence) = makeAppState(fetch: .success([message(id: 1)]))
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.activityEvents.map(\.kind), [.draftCreated])
        let event = appState.activityEvents.first
        XCTAssertEqual(event?.subject, "Subject 1")
        XCTAssertEqual(event?.messageUID, 1)
        XCTAssertEqual(event?.sourceMailHost, "imap.gmail.com")
        XCTAssertEqual(event?.sourceMailPort, 993)
        // Persisted durably.
        XCTAssertEqual(persistence.loadActivityEvents().map(\.kind), [.draftCreated])
    }

    func testSkipRecordsDurableActivityEventWithReason() async {
        // Closes item 17's deferred "skip reasons visible in the activity log".
        let (appState, _, persistence) = makeAppState(
            fetch: .success([message(id: 1, from: "no-reply@x.com")])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.activityEvents.map(\.kind), [.skipped])
        XCTAssertEqual(appState.activityEvents.first?.skipReason, .noReplySender)
        XCTAssertEqual(appState.activityEvents.first?.sourceMailHost, "imap.gmail.com")
        XCTAssertEqual(appState.activityEvents.first?.sourceMailPort, 993)
        XCTAssertEqual(appState.activityEvents.first?.reasonHeadline, ReplyWorthinessReason.noReplySender.headline)
        // Durable: survives even though the in-memory override entry does not.
        XCTAssertEqual(persistence.loadActivityEvents().first?.skipReason, .noReplySender)
    }

    func testSkipActivityRefreshesExistingEventInsteadOfDuplicating() throws {
        let (appState, _, persistence) = makeAppState()
        let oldEventID = UUID()
        let oldEvent = ActivityEvent(
            id: oldEventID,
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .skipped,
            account: "ME@GMAIL.COM",
            mailbox: "INBOX",
            sourceMailHost: "IMAP.GMAIL.COM",
            sourceMailPort: 993,
            sender: "Old sender",
            subject: "Old subject",
            skipReason: .bulkOrListMail,
            messageUID: 1,
            messageUIDValidity: 7
        )
        appState.activityEvents = [ActivityEvent(kind: .approvedSent, subject: "Keep"), oldEvent]

        let entry = SkippedMessage(
            message: message(id: 1, from: "no-reply@x.com"),
            mailbox: .inbox,
            account: "me@gmail.com",
            reason: .noReplySender
        )
        appState.recordSkipActivity(for: entry)

        XCTAssertEqual(appState.activityEvents.count, 2)
        let refreshed = try XCTUnwrap(appState.activityEvents.first)
        XCTAssertEqual(refreshed.id, oldEventID)
        XCTAssertEqual(refreshed.subject, "Subject 1")
        XCTAssertEqual(refreshed.skipReason, .noReplySender)
        XCTAssertGreaterThan(refreshed.timestamp, oldEvent.timestamp)
        XCTAssertEqual(persistence.loadActivityEvents().map(\.id), appState.activityEvents.map(\.id))
    }

    // MARK: - Approve / deny / send-failure streams

    func testApproveAutoSendRecordsSentEvent() async {
        let draft = pendingDraft()
        let (appState, _, _) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.activityEvents.map(\.kind), [.approvedSent])
        XCTAssertEqual(appState.activityEvents.first?.subject, "Lunch?")
    }

    func testApproveSaveAsDraftRecordsSavedEvent() async {
        let draft = pendingDraft()
        let (appState, _, _) = makeAppState(sendBehavior: .saveAsDraft, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.activityEvents.map(\.kind), [.approvedSaved])
    }

    func testDenyRecordsDeniedEvent() async {
        let draft = pendingDraft()
        let (appState, _, _) = makeAppState(seed: [draft])

        appState.denyDraft(draft)

        XCTAssertEqual(appState.activityEvents.map(\.kind), [.denied])
        XCTAssertEqual(appState.activityEvents.first?.subject, "Lunch?")
    }

    func testPreviewCountdownCancelRecordsSendCanceledEvent() {
        let draft = pendingDraft()
        let (appState, _, _) = makeAppState(seed: [draft])

        appState.recordDraftPreviewSendCancellation(for: draft)

        XCTAssertEqual(appState.activityEvents.map(\.kind), [.sendCanceled])
        XCTAssertEqual(appState.activityEvents.first?.subject, "Lunch?")
    }

    func testSendFailureRecordsSendFailedEvent() async {
        let draft = pendingDraft()
        // A permanent rejection (not a transient network error) records .sendFailed.
        let (appState, _, _) = makeAppState(
            sendBehavior: .autoSend,
            sendResult: .failure(.commandFailed("mailbox unavailable")),
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.activityEvents.map(\.kind), [.sendFailed])
        XCTAssertNotNil(appState.activityEvents.first?.detail)
        // The draft stays queued after a send failure.
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
    }

    func testTransientSendFailureRecordsRetryExhaustedEvent() async {
        let draft = pendingDraft()
        // A transient network failure that survives every retry records
        // .retryExhausted rather than .sendFailed (item 27).
        let (appState, provider, _) = makeAppState(
            sendBehavior: .autoSend,
            sendResult: .failure(.connectionFailed("smtp down")),
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.activityEvents.map(\.kind), [.retryExhausted])
        // The transient send was retried up to the attempt budget.
        XCTAssertEqual(provider.sendCallCount, RetryPolicy.default.maxAttempts)
        // The draft stays queued so the user can retry.
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
    }

    func testStaleWarningEventCarriesReason() {
        let (appState, _, _) = makeAppState()
        let draft = pendingDraft()

        appState.recordDraftActivity(.staleWarning, for: draft, staleReason: .sourceMissing)

        XCTAssertEqual(appState.activityEvents.map(\.kind), [.staleWarning])
        XCTAssertEqual(appState.activityEvents.first?.staleReason, .sourceMissing)
        XCTAssertEqual(appState.activityEvents.first?.reasonHeadline, StaleThreadReason.sourceMissing.headline)
    }

    // MARK: - Privacy

    func testDraftEventDoesNotPersistBodyOrReplyContent() async {
        let draft = pendingDraft()
        let (appState, _, _) = makeAppState(seed: [draft])

        appState.denyDraft(draft)
        let event = try? XCTUnwrap(appState.activityEvents.first)
        // Only metadata is captured; the reply body / incoming body are absent.
        XCTAssertEqual(event?.subject, "Lunch?")
        XCTAssertNil(event?.detail)
    }

    // MARK: - Link back to source

    func testCanOpenActivityEventWhenAccountMatchesAndUIDPresent() {
        let (appState, _, _) = makeAppState()
        appState.isAccountConnected = true
        let event = ActivityEvent(
            kind: .draftCreated,
            account: "me@gmail.com",
            mailbox: "INBOX",
            sourceMailHost: "IMAP.GMAIL.COM",
            sourceMailPort: 993,
            messageUID: 5,
            messageUIDValidity: 7
        )

        XCTAssertTrue(appState.canOpenActivityEvent(event))
    }

    func testCannotOpenActivityEventForDifferentAccount() {
        let (appState, _, _) = makeAppState()
        appState.isAccountConnected = true
        let event = ActivityEvent(
            kind: .draftCreated,
            account: "someone-else@gmail.com",
            mailbox: "INBOX",
            sourceMailHost: "imap.gmail.com",
            sourceMailPort: 993,
            messageUID: 5,
            messageUIDValidity: 7
        )

        XCTAssertFalse(appState.canOpenActivityEvent(event))
    }

    func testCannotOpenActivityEventWithoutUID() {
        let (appState, _, _) = makeAppState()
        appState.isAccountConnected = true
        let event = ActivityEvent(
            kind: .skipped,
            account: "me@gmail.com",
            mailbox: "INBOX",
            sourceMailHost: "imap.gmail.com",
            sourceMailPort: 993
        )

        XCTAssertFalse(appState.canOpenActivityEvent(event))
    }

    func testCannotOpenActivityEventWithoutUIDValidity() {
        let (appState, _, _) = makeAppState()
        appState.isAccountConnected = true
        let event = ActivityEvent(
            kind: .draftCreated,
            account: "me@gmail.com",
            mailbox: "INBOX",
            sourceMailHost: "imap.gmail.com",
            sourceMailPort: 993,
            messageUID: 5
        )

        XCTAssertFalse(appState.canOpenActivityEvent(event))
    }

    func testCannotOpenActivityEventWithoutSourceServer() {
        let (appState, _, _) = makeAppState()
        appState.isAccountConnected = true
        let event = ActivityEvent(
            kind: .draftCreated,
            account: "me@gmail.com",
            mailbox: "INBOX",
            messageUID: 5,
            messageUIDValidity: 7
        )

        XCTAssertFalse(appState.canOpenActivityEvent(event))
    }

    func testCannotOpenActivityEventForDifferentMailHost() {
        let (appState, _, _) = makeAppState()
        appState.isAccountConnected = true
        let event = ActivityEvent(
            kind: .draftCreated,
            account: "me@gmail.com",
            mailbox: "INBOX",
            sourceMailHost: "imap.other.example",
            sourceMailPort: 993,
            messageUID: 5,
            messageUIDValidity: 7
        )

        XCTAssertFalse(appState.canOpenActivityEvent(event))
    }

    func testCannotOpenActivityEventForDifferentMailPort() {
        let (appState, _, _) = makeAppState()
        appState.isAccountConnected = true
        let event = ActivityEvent(
            kind: .draftCreated,
            account: "me@gmail.com",
            mailbox: "INBOX",
            sourceMailHost: "imap.gmail.com",
            sourceMailPort: 143,
            messageUID: 5,
            messageUIDValidity: 7
        )

        XCTAssertFalse(appState.canOpenActivityEvent(event))
    }

    func testOpenActivityEventDoesNotFetchWithoutUIDValidity() async {
        let (appState, provider, _) = makeAppState()
        appState.isAccountConnected = true
        let event = ActivityEvent(
            kind: .draftCreated,
            account: "me@gmail.com",
            mailbox: "INBOX",
            sourceMailHost: "imap.gmail.com",
            sourceMailPort: 993,
            subject: "Subject 5",
            messageUID: 5
        )

        let preview = await appState.openActivityEvent(event)

        XCTAssertNil(preview)
        XCTAssertEqual(provider.bodyFetchCallCount, 0)
    }

    func testOpenActivityEventFetchesSourceBodyPreview() async {
        let (appState, provider, _) = makeAppState()
        appState.isAccountConnected = true
        let existingPreview = MailBodyPreview(id: 99, subject: "Existing", text: "Keep this")
        appState.openedBody = existingPreview
        let event = ActivityEvent(
            kind: .draftCreated,
            account: "me@gmail.com",
            mailbox: "INBOX",
            sourceMailHost: "imap.gmail.com",
            sourceMailPort: 993,
            subject: "Subject 5",
            messageUID: 5,
            messageUIDValidity: 7
        )

        let preview = await appState.openActivityEvent(event)

        XCTAssertEqual(preview?.id, 5)
        XCTAssertEqual(provider.lastBodyUID, 5)
        XCTAssertEqual(provider.lastExpectedUIDValidity, 7)
        XCTAssertEqual(appState.openedBody, existingPreview)
    }
}
