import SentwiseMail
import XCTest
@testable import Sentwise

/// Tests for low-confidence "needs input" draft handling on `AppState` (item 13).
/// The load-bearing guarantee is that a flagged draft is never sent or saved —
/// not from the preview, not from the queue, not from a notification action.
@MainActor
final class AppStateLowConfidenceDraftTests: XCTestCase {

    private func inboxMessage(id: UInt32 = 5) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 1,
            from: MailAddress(name: "Alice", email: "alice@x.com"),
            replyTo: MailAddress(name: "Team", email: "team@x.com"),
            subject: "Can you approve the budget?",
            date: ""
        )
    }

    private let needsInfoResponse = """
    NEEDS_INFO: I can't approve the budget without the figure only you have.
    - The approved budget amount
    - Whether finance has signed off
    """

    private let notReplyWorthyResponse =
        "\(DraftGenerator.notReplyWorthySentinel) This looks like an automated receipt."

    private func makeConnectedAppState(
        completion: Result<LLMResponse, LLMError>
    ) -> (AppState, FakeAppMailProvider) {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendDelaySeconds: 0
        ))
        let provider = FakeAppMailProvider(
            result: .success(()),
            bodyResult: .success(Data("Please approve the Q3 budget.".utf8))
        )
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "app-pw"
        return (appState, provider)
    }

    // MARK: - Detection

    func testGenerateDraftFlagsWhenModelNeedsInfo() async {
        let (appState, _) = makeConnectedAppState(completion: .success(LLMResponse(text: needsInfoResponse)))

        let draft = await appState.generateDraft(for: inboxMessage())

        XCTAssertEqual(draft?.isFlagged, true)
        XCTAssertEqual(draft?.body, "", "a flagged draft carries no fabricated reply")
        XCTAssertEqual(draft?.needsInfo?.missing, ["The approved budget amount", "Whether finance has signed off"])
        XCTAssertNil(appState.draftError)
    }

    func testReadyDraftIsNotFlagged() async {
        let (appState, _) = makeConnectedAppState(
            completion: .success(LLMResponse(text: "Approved — go ahead."))
        )

        let draft = await appState.generateDraft(for: inboxMessage())

        XCTAssertEqual(draft?.isFlagged, false)
        XCTAssertEqual(draft?.body, "Approved — go ahead.")
    }

    func testGenerateDraftFlagsWhenModelSaysNoReplyNeeded() async {
        let (appState, _) = makeConnectedAppState(completion: .success(LLMResponse(text: notReplyWorthyResponse)))

        let draft = await appState.generateDraft(for: inboxMessage())

        XCTAssertEqual(draft?.isFlagged, true)
        XCTAssertEqual(draft?.body, "", "a not-reply-worthy draft carries no fabricated reply")
        XCTAssertNil(draft?.needsInfo)
        XCTAssertEqual(draft?.notReplyWorthy?.summary, "This looks like an automated receipt.")
    }

    // MARK: - No dispatch on a flagged draft

    func testFlaggedPreviewCannotBeSent() async {
        let (appState, provider) = makeConnectedAppState(completion: .success(LLMResponse(text: needsInfoResponse)))
        _ = await appState.generateDraft(for: inboxMessage())

        await appState.sendGeneratedDraft()

        XCTAssertNil(provider.sentRFC822, "a flagged draft must never be sent")
        XCTAssertNotNil(appState.draftError)
        XCTAssertNotNil(appState.generatedDraft, "the flagged draft stays for the user to resolve")
    }

    func testFlaggedPreviewCannotBeSaved() async {
        let (appState, provider) = makeConnectedAppState(completion: .success(LLMResponse(text: needsInfoResponse)))
        _ = await appState.generateDraft(for: inboxMessage())

        await appState.saveGeneratedDraftToDrafts()

        XCTAssertNil(provider.appendedRFC822, "a flagged draft must never be saved")
        XCTAssertNotNil(appState.draftError)
    }

    func testApproveDraftPreviewRejectsFlaggedDraft() async {
        let (appState, provider) = makeConnectedAppState(completion: .success(LLMResponse(text: needsInfoResponse)))
        guard let draft = await appState.generateDraft(for: inboxMessage()) else {
            return XCTFail("expected a flagged draft")
        }

        do {
            _ = try await appState.approveDraftPreview(draft)
            XCTFail("expected needsUserInput to be thrown")
        } catch {
            XCTAssertEqual(error as? DraftError, .needsUserInput)
        }
        XCTAssertNil(provider.sentRFC822)
        XCTAssertNil(provider.appendedRFC822)
    }

    // MARK: - The queue / auto-send path

    func testWatcherEnqueuesFlaggedDraft() async throws {
        let (appState, _) = makeConnectedAppState(completion: .success(LLMResponse(text: needsInfoResponse)))
        appState.watchStatus = .watching

        _ = try await appState.draftAndEnqueue(inboxMessage())

        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(appState.pendingDrafts.first?.isFlagged, true)
    }

    /// The core safety criterion: approving a flagged draft — including via a
    /// notification "Approve" in auto-send mode — never sends or saves it.
    func testApprovingAQueuedFlaggedDraftDoesNotSend() async throws {
        let (appState, provider) = makeConnectedAppState(completion: .success(LLMResponse(text: needsInfoResponse)))
        appState.sendBehavior = .autoSend
        appState.watchStatus = .watching
        _ = try await appState.draftAndEnqueue(inboxMessage())
        let draft = try XCTUnwrap(appState.pendingDrafts.first)

        await appState.approveDraft(draft, sendBehavior: .autoSend)

        XCTAssertNil(provider.sentRFC822, "auto-send must never fire on a flagged draft")
        XCTAssertNotNil(appState.approvalError)
        XCTAssertEqual(appState.pendingDrafts.count, 1, "the flagged draft stays in the queue")
    }

    func testReadyQueuedDraftStillSends() async throws {
        let (appState, provider) = makeConnectedAppState(
            completion: .success(LLMResponse(text: "Approved — proceed."))
        )
        appState.sendBehavior = .autoSend
        appState.watchStatus = .watching
        _ = try await appState.draftAndEnqueue(inboxMessage())
        let draft = try XCTUnwrap(appState.pendingDrafts.first)

        await appState.approveDraft(draft, sendBehavior: .autoSend)

        XCTAssertNotNil(provider.sentRFC822, "a normal draft still sends")
        XCTAssertNil(appState.approvalError)
    }
}
