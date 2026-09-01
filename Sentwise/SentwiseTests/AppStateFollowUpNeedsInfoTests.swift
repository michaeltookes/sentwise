import SentwiseMail
import XCTest
@testable import Sentwise

private actor RecordingSequencedFollowUpLLMProvider: LLMProviding {
    private var completions: [Result<LLMResponse, LLMError>]
    private(set) var requests: [LLMRequest] = []

    init(completions: [Result<LLMResponse, LLMError>]) {
        self.completions = completions
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        requests.append(request)
        let next = completions.isEmpty
            ? Result.success(LLMResponse(text: "Follow-up body."))
            : completions.removeFirst()
        return try next.get()
    }
}

@MainActor
final class AppStateFollowUpNeedsInfoTests: XCTestCase {

    private func makeAppState(
        llm: LLMProviding
    ) -> (AppState, FakeDraftNotifier, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let notifier = FakeDraftNotifier()
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: notifier
        )
        return (appState, notifier, persistence)
    }

    func testCreateFollowUpEnqueuesNeedsInfoAuthoredDraft() async throws {
        let llm = RecordingSequencedFollowUpLLMProvider(completions: [
            .success(LLMResponse(text: """
            NEEDS_INFO: I need one planning detail.
            - The launch date
            """))
        ])
        let (appState, notifier, persistence) = makeAppState(llm: llm)
        let ingested = try TranscriptIngest.fromPaste("Marcus: We need to confirm the launch date.")

        let draft = try await appState.createFollowUp(
            from: ingested,
            recipients: [MailAddress(email: "dana@example.com")]
        )

        XCTAssertTrue(draft.isAuthored)
        XCTAssertEqual(draft.body, "")
        XCTAssertEqual(draft.needsInfo, DraftNeedsInfo(
            summary: "I need one planning detail.",
            missing: ["The launch date"]
        ))
        XCTAssertEqual(draft.followUpContext, FollowUpDraftContext.transcript(ParsedTranscript(
            text: "Marcus: We need to confirm the launch date.",
            hasSpeakerLabels: true
        )))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.needsInfo, draft.needsInfo)
        XCTAssertEqual(notifier.notifiedDrafts.last?.identity, draft.identity)
    }

    func testCreateFollowUpPersistsCompleteSummaryContextForLongTranscript() async throws {
        let longTranscript = String(repeating: "Marcus: Detail that might matter later.\n", count: 500)
        let llm = RecordingSequencedFollowUpLLMProvider(completions: [
            .success(LLMResponse(text: "Start summary.")),
            .success(LLMResponse(text: "Middle summary.")),
            .success(LLMResponse(text: "Tail summary: Priya owns launch.")),
            .success(LLMResponse(text: "Follow-up body."))
        ])
        let (appState, _, persistence) = makeAppState(llm: llm)

        let draft = try await appState.createFollowUp(from: TranscriptIngest.fromPaste(longTranscript))

        let context = try XCTUnwrap(draft.followUpContext)
        XCTAssertEqual(context.source, .summary)
        XCTAssertTrue(context.text.contains("Start summary."))
        XCTAssertTrue(context.text.contains("Tail summary: Priya owns launch."))
        XCTAssertLessThanOrEqual(context.text.count, AppState.maxPersistedFollowUpContextChars)
        XCTAssertLessThanOrEqual(
            persistence.loadPendingDrafts().first?.followUpContext?.text.count ?? 0,
            AppState.maxPersistedFollowUpContextChars
        )
    }

    func testAnsweredNeedsInfoFollowUpRedraftsWithFacts() async throws {
        let llm = RecordingSequencedFollowUpLLMProvider(completions: [
            .success(LLMResponse(text: """
            NEEDS_INFO: I need one planning detail.
            - The launch date
            """)),
            .success(LLMResponse(text: "Hi team,\n\nWe will launch on Aug 6."))
        ])
        let (appState, _, _) = makeAppState(llm: llm)
        let draft = try await appState.createFollowUp(
            from: TranscriptIngest.fromPaste("Marcus: We need to confirm the launch date."),
            recipients: [MailAddress(email: "dana@example.com")]
        )

        await appState.redraftPendingDraftWithAnswers(
            draft,
            round: UserSuppliedFacts(answers: [.init(question: "The launch date", response: "Aug 6")])
        )

        let updated = try XCTUnwrap(appState.pendingDrafts.first)
        XCTAssertEqual(updated.identity, draft.identity)
        XCTAssertNil(updated.needsInfo)
        XCTAssertEqual(updated.body, "Hi team,\n\nWe will launch on Aug 6.")
        XCTAssertEqual(updated.authoredRecipients?.map(\.email), ["dana@example.com"])
        XCTAssertEqual(updated.followUpContext, draft.followUpContext)
        XCTAssertEqual(updated.userSuppliedFacts?.answers.first?.response, "Aug 6")
        let requests = await llm.requests
        XCTAssertTrue(requests.last?.messages.first?.content.contains("The launch date: Aug 6") ?? false)
    }

    func testAnsweredNeedsInfoFollowUpFlushesPendingRecipientEditBeforeRedraft() async throws {
        let llm = RecordingSequencedFollowUpLLMProvider(completions: [
            .success(LLMResponse(text: """
            NEEDS_INFO: I need one planning detail.
            - The launch date
            """)),
            .success(LLMResponse(text: "Hi team,\n\nWe will launch on Aug 6."))
        ])
        let (appState, _, _) = makeAppState(llm: llm)
        let draft = try await appState.createFollowUp(
            from: TranscriptIngest.fromPaste("Marcus: We need to confirm the launch date."),
            recipients: [MailAddress(email: "old@example.com")]
        )
        appState.notePendingDraftRecipientEdit(
            draft,
            recipients: [MailAddress(email: "new@example.com")]
        )

        await appState.redraftPendingDraftWithAnswers(
            draft,
            round: UserSuppliedFacts(answers: [.init(question: "The launch date", response: "Aug 6")])
        )

        let updated = try XCTUnwrap(appState.pendingDrafts.first)
        XCTAssertEqual(updated.authoredRecipients?.map(\.email), ["new@example.com"])
        XCTAssertEqual(updated.sourceFrom?.email, "new@example.com")
        XCTAssertNil(appState.pendingDraftUncommittedEditRecipients[draft.identity])
        XCTAssertFalse(appState.pendingDraftUncommittedEditIDs.contains(draft.identity))
    }
}
