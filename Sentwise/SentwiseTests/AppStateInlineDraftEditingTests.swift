import SentwiseMail
import XCTest
@testable import Sentwise

/// Coverage for inline draft editing before send (item 19): the edited body is
/// exactly what dispatches, the edit persists across relaunch, the assistant's
/// original body is retained for future voice tuning, stale-thread checks still
/// run on edited drafts, and the save-failure activity rider is symmetric with
/// the send path.
@MainActor
final class AppStateInlineDraftEditingTests: XCTestCase {

    private func pendingDraft(
        id: UInt32 = 1,
        body: String = "Thursday works!",
        needsInfo: DraftNeedsInfo? = nil,
        notReplyWorthy: DraftNotReplyWorthy? = nil
    ) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: "INBOX",
            sourceSubject: "Lunch?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: Lunch?",
            body: body,
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            needsInfo: needsInfo,
            notReplyWorthy: notReplyWorthy
        )
    }

    private func makeAppState(
        sendBehavior: SendBehavior = .autoSend,
        appendResult: Result<Void, MailError> = .success(()),
        notifier: DraftNotifying = NullDraftNotifier(),
        seed drafts: [Draft] = []
    ) -> (AppState, FakeAppMailProvider, AppStateMemoryPersistence) {
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
        let provider = FakeAppMailProvider(result: .success(()), appendResult: appendResult)
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: notifier
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return (appState, provider, persistence)
    }

    private func makeConnectedAppState(persistence: AppStateMemoryPersistence) -> AppState {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        return AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    /// Decodes the base64 text/plain body from an outgoing RFC 822 message.
    /// `OutgoingMessage.rfc822()` base64-encodes the body (Content-Transfer-
    /// Encoding: base64), so the reply text is not a literal substring — assert
    /// on the decoded body instead.
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

    // MARK: - Draft model

    func testApplyEditedBodyCapturesOriginalOnceAndTracksLatest() {
        var draft = pendingDraft(body: "Generated reply.")
        XCTAssertFalse(draft.wasEdited)
        XCTAssertNil(draft.originalBody)

        draft.applyEditedBody("First edit.")
        XCTAssertEqual(draft.body, "First edit.")
        XCTAssertEqual(draft.originalBody, "Generated reply.")
        XCTAssertTrue(draft.wasEdited)

        draft.applyEditedBody("Second edit.")
        XCTAssertEqual(draft.body, "Second edit.")
        // The original is captured only on first divergence, not overwritten.
        XCTAssertEqual(draft.originalBody, "Generated reply.")
    }

    func testApplyEditedBodyIsNoOpWhenUnchanged() {
        var draft = pendingDraft(body: "Same.")
        draft.applyEditedBody("Same.")
        XCTAssertNil(draft.originalBody)
        XCTAssertFalse(draft.wasEdited)
    }

    func testWasEditedFalseWhenRevertedToOriginal() {
        var draft = pendingDraft(body: "Original.")
        draft.applyEditedBody("Changed.")
        draft.applyEditedBody("Original.")
        XCTAssertEqual(draft.body, "Original.")
        // Original stays captured, but a body equal to it reads as not edited.
        XCTAssertFalse(draft.wasEdited)
    }

    func testEditingBodyDoesNotChangeIdentity() {
        var draft = pendingDraft(body: "Before.")
        let identity = draft.identity
        draft.applyEditedBody("After.")
        XCTAssertEqual(draft.identity, identity)
    }

    func testNotReplyWorthyDraftStaysFlaggedUntilUserWritesReply() {
        var draft = pendingDraft(
            body: "",
            notReplyWorthy: DraftNotReplyWorthy(summary: "This receipt does not need a reply.")
        )
        XCTAssertTrue(draft.isFlagged)

        draft.applyEditedBody("Thanks for sending this over.")

        XCTAssertFalse(draft.isFlagged)
    }

    // MARK: - Edited body is what dispatches

    func testEditedBodyIsWhatSends() async {
        let draft = pendingDraft(body: "Generated reply body.")
        let (appState, provider, _) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approvePendingDraft(draft, withEditedBody: "My hand-written reply.")

        XCTAssertEqual(decodedBody(from: provider.sentRFC822), "My hand-written reply.")
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testEditedNotReplyWorthyOverrideIsWhatSends() async {
        let draft = pendingDraft(
            body: "",
            notReplyWorthy: DraftNotReplyWorthy(summary: "This receipt does not need a reply.")
        )
        let (appState, provider, _) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approvePendingDraft(draft, withEditedBody: "Thanks for the receipt.")

        XCTAssertEqual(decodedBody(from: provider.sentRFC822), "Thanks for the receipt.")
        XCTAssertNil(appState.approvalError)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testEmptyNotReplyWorthyOverrideStillDoesNotSend() async {
        let draft = pendingDraft(
            body: "",
            notReplyWorthy: DraftNotReplyWorthy(summary: "This receipt does not need a reply.")
        )
        let (appState, provider, _) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approvePendingDraft(draft, withEditedBody: "  \n")

        XCTAssertNil(provider.sentRFC822)
        XCTAssertNotNil(appState.approvalError)
        XCTAssertEqual(appState.pendingDrafts.count, 1)
    }

    func testEditedBodyIsWhatSaves() async {
        let draft = pendingDraft(body: "Generated reply body.")
        let (appState, provider, _) = makeAppState(sendBehavior: .saveAsDraft, seed: [draft])

        await appState.approvePendingDraft(draft, withEditedBody: "Edited save body.")

        XCTAssertEqual(decodedBody(from: provider.appendedRFC822), "Edited save body.")
        XCTAssertEqual(provider.appendedMailbox, .drafts)
    }

    func testPreviewApproveDispatchesEditedBody() async {
        let (appState, provider, _) = makeAppState(sendBehavior: .autoSend)
        var draft = pendingDraft(body: "Generated preview body.")
        appState.generatedDraft = draft
        draft.applyEditedBody("Edited preview body.")

        let confirmation = try? await appState.approveDraftPreview(draft)

        XCTAssertEqual(confirmation, "Sent.")
        XCTAssertEqual(decodedBody(from: provider.sentRFC822), "Edited preview body.")
        // The edited draft still clears the stored preview (identity match).
        XCTAssertNil(appState.generatedDraft)
    }

    // MARK: - Persistence + original retention

    func testEditPersistsAndRetainsOriginal() {
        let draft = pendingDraft(body: "Generated.")
        let (appState, _, persistence) = makeAppState(seed: [draft])

        appState.updatePendingDraftBody(draft, to: "Persisted edit.")

        XCTAssertEqual(appState.pendingDrafts.first?.body, "Persisted edit.")
        XCTAssertEqual(appState.pendingDrafts.first?.originalBody, "Generated.")
        XCTAssertEqual(persistence.loadPendingDrafts().first?.body, "Persisted edit.")
        XCTAssertEqual(persistence.loadPendingDrafts().first?.originalBody, "Generated.")
    }

    func testEditSurvivesSimulatedRelaunch() {
        let draft = pendingDraft(body: "Generated.")
        let (appState, _, persistence) = makeAppState(seed: [draft])

        appState.updatePendingDraftBody(draft, to: "Edit before restart.")

        // A fresh AppState loads pending drafts from the same persistence.
        let relaunched = makeConnectedAppState(persistence: persistence)
        XCTAssertEqual(relaunched.pendingDrafts.first?.body, "Edit before restart.")
        XCTAssertEqual(relaunched.pendingDrafts.first?.originalBody, "Generated.")
    }

    func testEditPersistenceRefreshesNotificationCopyQuietly() {
        let draft = pendingDraft(body: "Generated.")
        let notifier = FakeDraftNotifier()
        let (appState, _, _) = makeAppState(notifier: notifier, seed: [draft])

        appState.updatePendingDraftBody(draft, to: "Edited.")

        XCTAssertTrue(notifier.notifiedDrafts.isEmpty)
        XCTAssertEqual(notifier.refreshedDrafts.map(\.body), ["Edited."])
    }

    func testUpdatePendingDraftBodyIsNoOpWhenUnchanged() {
        let draft = pendingDraft(body: "Unchanged.")
        let (appState, _, persistence) = makeAppState(seed: [draft])
        let before = persistence.pendingDraftSaveCount

        let result = appState.updatePendingDraftBody(draft, to: "Unchanged.")

        XCTAssertEqual(result?.body, "Unchanged.")
        XCTAssertNil(result?.originalBody)
        XCTAssertEqual(persistence.pendingDraftSaveCount, before)
    }

    func testUpdatePendingDraftBodyReturnsNilWhenNotQueued() {
        let (appState, _, _) = makeAppState(seed: [])
        let orphan = pendingDraft(id: 99, body: "Orphan.")

        let result = appState.updatePendingDraftBody(orphan, to: "Edited.")

        XCTAssertNil(result)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testUpdatePendingDraftBodyRollsBackOnPersistenceFailure() {
        let draft = pendingDraft(body: "Generated.")
        let (appState, _, persistence) = makeAppState(seed: [draft])
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        let result = appState.updatePendingDraftBody(draft, to: "Edited.")

        XCTAssertNil(result)
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Generated.")
        XCTAssertNil(appState.pendingDrafts.first?.originalBody)
        XCTAssertNotNil(appState.approvalError)
    }

    func testApprovePendingDraftStopsWhenEditPersistenceFails() async {
        let draft = pendingDraft(body: "Generated.")
        let (appState, provider, persistence) = makeAppState(seed: [draft])
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        await appState.approvePendingDraft(draft, withEditedBody: "Edited.")

        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Generated.")
        XCTAssertNotNil(appState.approvalError)
    }

    func testNotificationApprovalOpensReviewWhenInlineEditIsUncommitted() async {
        let draft = pendingDraft(body: "Generated.")
        let (appState, provider, _) = makeAppState(seed: [draft])
        var opened = false
        appState.openReviewHandler = { opened = true }
        appState.notePendingDraftBodyEdit(draft, editedBody: "Edited.")

        await appState.handleNotificationAction(.approve(.autoSend), identity: draft.identity)

        XCTAssertTrue(opened)
        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Generated.")
        XCTAssertNotNil(appState.approvalError)
    }

    func testNotificationApprovalUsesDurableInlineEditAfterDebouncedPersist() async {
        let draft = pendingDraft(body: "Generated.")
        let (appState, provider, _) = makeAppState(seed: [draft])
        appState.notePendingDraftBodyEdit(draft, editedBody: "Edited.")

        let persisted = appState.updatePendingDraftBody(draft, to: "Edited.")
        await appState.handleNotificationAction(.approve(.autoSend), identity: draft.identity)

        XCTAssertEqual(persisted?.body, "Edited.")
        XCTAssertEqual(decodedBody(from: provider.sentRFC822), "Edited.")
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testFlushPendingDraftBodyEditsPersistsQueuedEdit() {
        let draft = pendingDraft(body: "Generated.")
        let (appState, _, persistence) = makeAppState(seed: [draft])
        appState.notePendingDraftBodyEdit(draft, editedBody: "Edited before quit.")

        appState.flushPendingDraftBodyEdits()

        XCTAssertEqual(appState.pendingDrafts.first?.body, "Edited before quit.")
        XCTAssertEqual(persistence.loadPendingDrafts().first?.body, "Edited before quit.")
        XCTAssertFalse(appState.pendingDraftUncommittedEditIDs.contains(draft.identity))
        XCTAssertNil(appState.pendingDraftUncommittedEditBodies[draft.identity])
    }

    func testFlushPendingDraftBodyEditsKeepsQueuedEditOnFailure() {
        let draft = pendingDraft(body: "Generated.")
        let (appState, _, persistence) = makeAppState(seed: [draft])
        appState.notePendingDraftBodyEdit(draft, editedBody: "Edited before quit.")
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        appState.flushPendingDraftBodyEdits()

        XCTAssertEqual(appState.pendingDrafts.first?.body, "Generated.")
        XCTAssertEqual(appState.pendingDraftUncommittedEditBodies[draft.identity], "Edited before quit.")
        XCTAssertTrue(appState.pendingDraftUncommittedEditIDs.contains(draft.identity))
        XCTAssertNotNil(appState.approvalError)
    }

    // MARK: - Stale checks still run on edited drafts

    func testStaleThreadCheckStillEnforcedAfterEdit() async {
        let draft = pendingDraft(id: 5)
        let provider = SearchStubMailProvider(
            threadResult: MailSearchResult(
                // A newer reply (UID 9 > source UID 5) from the same sender is a
                // genuine related follow-up, so the thread reads as stale. The
                // sender is required: relatedThreadMessages only links a
                // same-subject message when it shares a thread participant.
                messages: [
                    MailMessage(
                        id: 5,
                        uidValidity: 10,
                        from: MailAddress(name: "Alice", email: "alice@example.com"),
                        subject: "Lunch?",
                        date: "",
                        messageID: "<orig@example.com>"
                    ),
                    MailMessage(
                        id: 9,
                        uidValidity: 10,
                        from: MailAddress(name: "Alice", email: "alice@example.com"),
                        subject: "Re: Lunch?",
                        date: ""
                    )
                ],
                totalMatches: 2,
                offset: 0,
                hasMore: false
            )
        )
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
        ), pendingDrafts: [draft])
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        appState.pendingDrafts = [draft]
        appState.pendingDraftCount = 1

        await appState.approvePendingDraft(draft, withEditedBody: "Edited but the thread moved on.")

        // The edit did not bypass the stale-thread gate.
        XCTAssertEqual(appState.pendingStaleWarnings[draft.identity], .newerReplyInThread)
        XCTAssertEqual(provider.sendCount, 0)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        // The edit still persisted so it is not lost when the user resolves the warning.
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Edited but the thread moved on.")
    }

    // MARK: - Activity signal

    func testApprovedSentActivityNotesEditedBeforeSend() async {
        let draft = pendingDraft()
        let (appState, _, _) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approvePendingDraft(draft, withEditedBody: "Edited reply.")

        let sent = appState.activityEvents.first { $0.kind == .approvedSent }
        XCTAssertEqual(sent?.detail, "Edited before send")
    }

    func testApprovedSavedActivityNotesEditedBeforeSend() async {
        let draft = pendingDraft()
        let (appState, _, _) = makeAppState(sendBehavior: .saveAsDraft, seed: [draft])

        await appState.approvePendingDraft(draft, withEditedBody: "Edited reply.")

        let saved = appState.activityEvents.first { $0.kind == .approvedSaved }
        XCTAssertEqual(saved?.detail, "Edited before send")
    }

    func testUneditedApprovalHasNoEditDetail() async {
        let draft = pendingDraft()
        let (appState, _, _) = makeAppState(sendBehavior: .autoSend, seed: [draft])

        await appState.approveDraft(draft)

        let sent = appState.activityEvents.first { $0.kind == .approvedSent }
        XCTAssertNil(sent?.detail)
    }

    // MARK: - Save-failure rider (symmetry with send)

    func testSaveFailureRecordsSaveFailedActivity() async {
        let draft = pendingDraft()
        let (appState, _, _) = makeAppState(
            sendBehavior: .saveAsDraft,
            appendResult: .failure(.commandFailed("APPEND failed")),
            seed: [draft]
        )

        await appState.approveDraft(draft)

        XCTAssertTrue(appState.activityEvents.contains { $0.kind == .saveFailed })
        XCTAssertFalse(appState.activityEvents.contains { $0.kind == .approvedSaved })
        XCTAssertNotNil(appState.approvalError)
        // The draft is kept for another attempt.
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
    }

    func testSaveFailedActivityCarriesErrorDetail() async {
        let draft = pendingDraft()
        let (appState, _, _) = makeAppState(
            sendBehavior: .saveAsDraft,
            appendResult: .failure(.commandFailed("APPEND failed")),
            seed: [draft]
        )

        await appState.approveDraft(draft)

        let failure = appState.activityEvents.first { $0.kind == .saveFailed }
        XCTAssertNotNil(failure?.detail)
        XCTAssertFalse(failure?.detail?.isEmpty ?? true)
    }
}
