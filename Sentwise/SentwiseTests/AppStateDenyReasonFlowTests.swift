import SentwiseMail
import XCTest
@testable import Sentwise

/// Tests for the deny-reason picker state machine (item 83, Phase 1): must-pick
/// gating, mandatory Other text, clean cancel, remembered last reason, and the
/// per-session don't-ask-again fast path.
@MainActor
final class AppStateDenyReasonFlowTests: XCTestCase {

    private func pendingDraft(id: UInt32) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: "INBOX",
            sourceSubject: "Lunch \(id)?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig-\(id)@example.com>",
            incomingBody: "Are you free?",
            replySubject: "Re: Lunch \(id)?",
            body: "Sure!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeAppState(seed drafts: [Draft]) -> AppState {
        let secrets = InMemorySecretStore(seed: [.mailAppPassword: "app-pw"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            sendDelaySeconds: 0
        ), pendingDrafts: drafts)
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(()), appendResult: .success(()), sendResult: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier()
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return appState
    }

    func testRequestDenyPresentsPickerWithoutRemovingDraft() {
        let draft = pendingDraft(id: 1)
        let appState = makeAppState(seed: [draft])

        let presented = appState.requestDenyDraft(draft)

        XCTAssertTrue(presented)
        XCTAssertEqual(appState.denyReasonPrompt?.id, draft.identity)
        XCTAssertEqual(appState.denyReasonPrompt?.defaultCode, .notWorthReplying)
        XCTAssertTrue(appState.pendingDrafts.contains { $0.identity == draft.identity })
        XCTAssertTrue(appState.draftFeedbackRecords.isEmpty)
    }

    func testRequestDenyIsNoOpForNonPendingDraft() {
        let appState = makeAppState(seed: [])
        XCTAssertFalse(appState.requestDenyDraft(pendingDraft(id: 99)))
        XCTAssertNil(appState.denyReasonPrompt)
    }

    func testConfirmPresetFinalizesDenyAndRecords() {
        let draft = pendingDraft(id: 1)
        let appState = makeAppState(seed: [draft])
        _ = appState.requestDenyDraft(draft)

        appState.confirmDenyReason(code: .wrongContent, otherText: "", dontAskAgain: false)

        XCTAssertNil(appState.denyReasonPrompt)
        XCTAssertFalse(appState.pendingDrafts.contains { $0.identity == draft.identity })
        XCTAssertEqual(appState.draftFeedbackRecords.first?.denyReason?.code, .wrongContent)
    }

    func testConfirmOtherWithEmptyTextIsRejected() {
        let draft = pendingDraft(id: 1)
        let appState = makeAppState(seed: [draft])
        _ = appState.requestDenyDraft(draft)

        appState.confirmDenyReason(code: .other, otherText: "   ", dontAskAgain: false)

        // Deny does not complete: the prompt stays and the draft is untouched.
        XCTAssertNotNil(appState.denyReasonPrompt)
        XCTAssertTrue(appState.pendingDrafts.contains { $0.identity == draft.identity })
        XCTAssertTrue(appState.draftFeedbackRecords.isEmpty)
    }

    func testConfirmOtherWithTextRecordsFreeText() {
        let draft = pendingDraft(id: 1)
        let appState = makeAppState(seed: [draft])
        _ = appState.requestDenyDraft(draft)

        appState.confirmDenyReason(code: .other, otherText: "cold outreach", dontAskAgain: false)

        XCTAssertNil(appState.denyReasonPrompt)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.denyReason?.code, .other)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.denyReason?.otherText, "cold outreach")
    }

    func testCancelAbortsDenyCleanly() {
        let draft = pendingDraft(id: 1)
        let appState = makeAppState(seed: [draft])
        _ = appState.requestDenyDraft(draft)

        appState.cancelDenyReason()

        XCTAssertNil(appState.denyReasonPrompt)
        XCTAssertTrue(appState.pendingDrafts.contains { $0.identity == draft.identity })
        XCTAssertTrue(appState.draftFeedbackRecords.isEmpty)
        XCTAssertTrue(appState.activityEvents.isEmpty)
    }

    func testRemembersLastReasonAsPickerDefault() {
        let first = pendingDraft(id: 1)
        let second = pendingDraft(id: 2)
        let appState = makeAppState(seed: [first, second])

        _ = appState.requestDenyDraft(first)
        appState.confirmDenyReason(code: .handleLater, otherText: "", dontAskAgain: false)

        // The next deny pre-selects the remembered reason.
        let presented = appState.requestDenyDraft(second)
        XCTAssertTrue(presented)
        XCTAssertEqual(appState.denyReasonPrompt?.defaultCode, .handleLater)
    }

    func testDontAskAgainReusesLastReasonSilently() {
        let first = pendingDraft(id: 1)
        let second = pendingDraft(id: 2)
        let appState = makeAppState(seed: [first, second])

        _ = appState.requestDenyDraft(first)
        appState.confirmDenyReason(code: .wrongTone, otherText: "", dontAskAgain: true)
        XCTAssertEqual(appState.draftFeedbackRecords.count, 1)

        // The second deny does not present a picker; it finalizes immediately.
        let presented = appState.requestDenyDraft(second)
        XCTAssertFalse(presented)
        XCTAssertNil(appState.denyReasonPrompt)
        XCTAssertFalse(appState.pendingDrafts.contains { $0.identity == second.identity })
        // Still recorded, reusing the remembered reason.
        XCTAssertEqual(appState.draftFeedbackRecords.count, 2)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.denyReason?.code, .wrongTone)
    }

    func testDontAskAgainRemembersOtherFreeText() {
        let first = pendingDraft(id: 1)
        let second = pendingDraft(id: 2)
        let appState = makeAppState(seed: [first, second])

        _ = appState.requestDenyDraft(first)
        appState.confirmDenyReason(code: .other, otherText: "automated alert", dontAskAgain: true)

        _ = appState.requestDenyDraft(second)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.denyReason?.code, .other)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.denyReason?.otherText, "automated alert")
    }

    func testConfirmDenyReasonIsNoOpWhenDraftAlreadyLeftQueue() async {
        let draft = pendingDraft(id: 1)
        let appState = makeAppState(seed: [draft])
        _ = appState.requestDenyDraft(draft)

        await appState.approveDraft(draft)
        appState.confirmDenyReason(code: .wrongContent, otherText: "", dontAskAgain: true)

        XCTAssertEqual(appState.draftFeedbackRecords.count, 1)
        XCTAssertEqual(appState.draftFeedbackRecords.first?.outcome, .approvedAsIs)
        XCTAssertNil(appState.activityEvents.first(where: { $0.kind == .denied }))
        XCTAssertNil(appState.lastUsedDenyReason)
        XCTAssertFalse(appState.denyReasonPromptSuppressedThisSession)
    }
}
