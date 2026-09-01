import SentwiseMail
import XCTest
@testable import Sentwise

/// Tests that the approve/deny paths record the right approval-signal feedback
/// (item 83, Phase 1), that the store survives relaunch, and that it caps.
@MainActor
final class AppStateApprovalFeedbackTests: XCTestCase {

    private func pendingDraft(
        id: UInt32 = 1,
        body: String = "Thursday works!",
        originalBody: String? = nil,
        replyWorthinessOverride: Bool = false,
        userSuppliedFacts: UserSuppliedFacts? = nil,
        authoredRecipients: [MailAddress]? = nil,
        manualPreview: Bool = false
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
            originalBody: originalBody,
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            authoredRecipients: authoredRecipients,
            replyWorthinessOverride: replyWorthinessOverride,
            manualPreview: manualPreview,
            userSuppliedFacts: userSuppliedFacts
        )
    }

    private func makeAppState(
        sendBehavior: SendBehavior = .autoSend,
        seed drafts: [Draft] = []
    ) -> (AppState, AppStateMemoryPersistence) {
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
        let provider = FakeAppMailProvider(result: .success(()), appendResult: .success(()), sendResult: .success(()))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier()
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return (appState, persistence)
    }

    // MARK: - Approval capture

    func testApproveAsIsRecordsApprovedAsIsSent() async {
        let draft = pendingDraft()
        let (appState, persistence) = makeAppState(seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.draftFeedbackRecords.count, 1)
        let record = appState.draftFeedbackRecords[0]
        XCTAssertEqual(record.outcome, .approvedAsIs)
        XCTAssertEqual(record.dispatch, .sent)
        XCTAssertNil(record.editMagnitude)
        XCTAssertNil(record.denyReason)
        XCTAssertEqual(record.provenance, .watcher)
        XCTAssertFalse(record.answeredNeedsInfo)
        XCTAssertEqual(record.draftIdentityHash, DraftFeedbackRecord.hashedIdentity(draft.identity))
        // Persisted, not just in memory.
        XCTAssertEqual(persistence.draftFeedback.count, 1)
    }

    func testApproveSaveAsDraftRecordsSaved() async {
        let draft = pendingDraft()
        let (appState, _) = makeAppState(sendBehavior: .saveAsDraft, seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.draftFeedbackRecords.first?.outcome, .approvedAsIs)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.dispatch, .saved)
    }

    func testApproveAfterEditRecordsMagnitude() async {
        let draft = pendingDraft(body: "Thursday works for us all", originalBody: "Thursday works")
        let (appState, _) = makeAppState(seed: [draft])

        await appState.approveDraft(draft)

        let record = appState.draftFeedbackRecords.first
        XCTAssertEqual(record?.outcome, .approvedAfterEdit)
        XCTAssertNotNil(record?.editMagnitude)
        XCTAssertGreaterThan(record?.editMagnitude ?? 0, 0)
        XCTAssertLessThanOrEqual(record?.editMagnitude ?? 1, 1)
    }

    func testApproveAnsweredNeedsInfoDraftRecordsAnswered() async {
        let facts = UserSuppliedFacts(answers: [.init(question: "When?", response: "Thursday 3pm")])
        let draft = pendingDraft(userSuppliedFacts: facts)
        let (appState, _) = makeAppState(seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertTrue(appState.draftFeedbackRecords.first?.answeredNeedsInfo ?? false)
    }

    func testApproveDraftAnywayRecordsDraftAnywayProvenance() async {
        let draft = pendingDraft(replyWorthinessOverride: true)
        let (appState, _) = makeAppState(seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.draftFeedbackRecords.first?.provenance, .draftAnyway)
    }

    func testApproveAuthoredDraftRecordsAuthoredProvenance() async {
        let draft = pendingDraft(authoredRecipients: [MailAddress(email: "dana@example.com")])
        let (appState, _) = makeAppState(seed: [draft])

        await appState.approveDraft(draft)

        XCTAssertEqual(appState.draftFeedbackRecords.first?.provenance, .authored)
    }

    func testApproveManualPreviewRecordsManualPreviewProvenance() async throws {
        let draft = pendingDraft(manualPreview: true)
        let (appState, _) = makeAppState(seed: [])

        _ = try await appState.approveDraftPreview(draft, sendBehavior: .autoSend)

        XCTAssertEqual(appState.draftFeedbackRecords.first?.provenance, .manualPreview)
    }

    func testRegeneratedManualPreviewPreservesManualPreviewProvenance() {
        let draft = pendingDraft(manualPreview: true)
        var replacement = pendingDraft(id: 2)
        let (appState, _) = makeAppState(seed: [])

        appState.preserveRegenerationProvenance(from: draft, on: &replacement)

        XCTAssertEqual(replacement.manualPreview, true)
        XCTAssertEqual(replacement.feedbackProvenance, .manualPreview)
    }

    func testManualPreviewAbandonmentRecordsTerminalFeedback() {
        let draft = pendingDraft(manualPreview: true)
        let (appState, _) = makeAppState(seed: [])

        appState.recordDraftPreviewAbandonment(for: draft)

        let record = appState.draftFeedbackRecords.first
        XCTAssertEqual(record?.outcome, .abandoned)
        XCTAssertEqual(record?.provenance, .manualPreview)
        XCTAssertNil(record?.dispatch)
        XCTAssertNil(record?.denyReason)
    }

    func testNonPreviewAbandonmentIsNoOp() {
        let draft = pendingDraft()
        let (appState, _) = makeAppState(seed: [])

        appState.recordDraftPreviewAbandonment(for: draft)

        XCTAssertTrue(appState.draftFeedbackRecords.isEmpty)
    }

    func testPreviewApprovalRecordsEditedSentFeedback() async throws {
        let draft = pendingDraft(
            body: "Thursday works for me.",
            originalBody: "Thursday works!"
        )
        let (appState, _) = makeAppState(seed: [])
        appState.generatedDraft = draft

        let confirmation = try await appState.approveDraftPreview(draft, sendBehavior: .autoSend)

        XCTAssertEqual(confirmation, "Sent.")
        let record = appState.draftFeedbackRecords.first
        XCTAssertEqual(record?.outcome, .approvedAfterEdit)
        XCTAssertEqual(record?.dispatch, .sent)
        XCTAssertNotNil(record?.editMagnitude)
        XCTAssertNil(record?.denyReason)
        XCTAssertNil(appState.generatedDraft)
    }

    func testPreviewApprovalRecordsSavedFeedback() async throws {
        let draft = pendingDraft()
        let (appState, _) = makeAppState(seed: [])

        let confirmation = try await appState.approveDraftPreview(draft, sendBehavior: .saveAsDraft)

        XCTAssertEqual(confirmation, "Saved to your Drafts.")
        XCTAssertEqual(appState.draftFeedbackRecords.first?.outcome, .approvedAsIs)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.dispatch, .saved)
    }

    func testGeneratedDraftSendRecordsApprovalFeedback() async {
        let draft = pendingDraft()
        let (appState, _) = makeAppState(seed: [])
        appState.generatedDraft = draft

        await appState.sendGeneratedDraft()

        XCTAssertEqual(appState.draftFeedbackRecords.first?.outcome, .approvedAsIs)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.dispatch, .sent)
    }

    func testGeneratedDraftSaveRecordsApprovalFeedback() async {
        let draft = pendingDraft()
        let (appState, _) = makeAppState(seed: [])
        appState.generatedDraft = draft

        await appState.saveGeneratedDraftToDrafts()

        XCTAssertEqual(appState.draftFeedbackRecords.first?.outcome, .approvedAsIs)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.dispatch, .saved)
    }

    // MARK: - Deny capture

    func testDenyWithReasonRecordsDeniedAndCodeOnlyInActivity() {
        let draft = pendingDraft()
        let (appState, _) = makeAppState(seed: [draft])

        appState.finalizeDenyDraft(draft, reason: DenyReason(code: .wrongTone))

        let record = appState.draftFeedbackRecords.first
        XCTAssertEqual(record?.outcome, .denied)
        XCTAssertEqual(record?.denyReason?.code, .wrongTone)
        // The activity denied event carries the code only, never free text.
        XCTAssertEqual(appState.activityEvents.first?.kind, .denied)
        XCTAssertEqual(appState.activityEvents.first?.detail, "wrong_tone")
    }

    func testDenyOtherKeepsFreeTextOutOfActivityHistory() {
        let draft = pendingDraft()
        let (appState, _) = makeAppState(seed: [draft])

        appState.finalizeDenyDraft(draft, reason: DenyReason(code: .other, otherText: "newsletter I never read"))

        XCTAssertEqual(appState.draftFeedbackRecords.first?.denyReason?.otherText, "newsletter I never read")
        // Activity detail is the code, and never the free text.
        XCTAssertEqual(appState.activityEvents.first?.detail, "other")
        XCTAssertNil(appState.activityEvents.first(where: { $0.detail?.contains("newsletter") == true }))
    }

    func testDenyAuthoredDraftRecordsAuthoredProvenance() {
        let draft = pendingDraft(authoredRecipients: [MailAddress(email: "dana@example.com")])
        let (appState, _) = makeAppState(seed: [draft])

        appState.finalizeDenyDraft(draft, reason: DenyReason(code: .handleLater))

        XCTAssertEqual(appState.draftFeedbackRecords.first?.outcome, .denied)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.provenance, .authored)
    }

    func testLegacyDenyRecordsDeniedWithNilReason() {
        let draft = pendingDraft()
        let (appState, _) = makeAppState(seed: [draft])

        appState.denyDraft(draft)

        XCTAssertEqual(appState.draftFeedbackRecords.first?.outcome, .denied)
        XCTAssertNil(appState.draftFeedbackRecords.first?.denyReason)
        XCTAssertNil(appState.activityEvents.first?.detail)
    }

    // MARK: - Durability + cap

    func testStoreSurvivesRelaunch() async {
        let draft = pendingDraft()
        let (appState, persistence) = makeAppState(seed: [draft])
        await appState.approveDraft(draft)
        XCTAssertEqual(persistence.draftFeedback.count, 1)

        // A fresh AppState over the same persistence restores the store.
        let relaunched = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(seed: [.mailAppPassword: "app-pw"]),
            mailProvider: FakeAppMailProvider(result: .success(()), appendResult: .success(()), sendResult: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier()
        )
        XCTAssertEqual(relaunched.draftFeedbackRecords.count, 1)
        XCTAssertEqual(relaunched.draftFeedbackRecords.first?.outcome, .approvedAsIs)
    }

    func testStoreCapsAndRotatesOldestOut() {
        let (appState, _) = makeAppState()
        let limit = appState.draftFeedbackLogLimit
        let hash = DraftFeedbackRecord.hashedIdentity("me@gmail.com|INBOX|10|1")

        for index in 0..<(limit + 5) {
            appState.recordDraftFeedback(DraftFeedbackRecord(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                outcome: .denied,
                denyReason: DenyReason(code: .handleLater),
                provenance: .watcher,
                answeredNeedsInfo: false,
                draftIdentityHash: hash
            ))
        }

        XCTAssertEqual(appState.draftFeedbackRecords.count, limit)
        // Newest first: the most recently recorded (highest timestamp) is at front.
        XCTAssertEqual(
            appState.draftFeedbackRecords.first?.timestamp,
            Date(timeIntervalSince1970: TimeInterval(limit + 4))
        )
        // The very first records were evicted (oldest dropped).
        XCTAssertFalse(appState.draftFeedbackRecords.contains {
            $0.timestamp == Date(timeIntervalSince1970: 0)
        })
    }
}
