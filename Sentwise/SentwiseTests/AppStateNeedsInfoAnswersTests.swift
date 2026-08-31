import SentwiseMail
import Foundation
import XCTest
@testable import Sentwise

/// A fake LLM that replays a scripted sequence of responses and records every
/// request, so the answer→re-draft loop (item 85) can be walked deterministically.
private final class ScriptedLLMProvider: LLMProviding, @unchecked Sendable {
    var responses: [String]
    var defaultResponse: String
    private(set) var requests: [LLMRequest] = []
    var completeCount: Int { requests.count }

    init(responses: [String], defaultResponse: String = "Fallback reply.") {
        self.responses = responses
        self.defaultResponse = defaultResponse
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        requests.append(request)
        let text = responses.isEmpty ? defaultResponse : responses.removeFirst()
        return LLMResponse(text: text)
    }
}

@MainActor
final class AppStateNeedsInfoAnswersTests: XCTestCase {

    private func message(id: UInt32, subject: String, messageID: String?) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 1,
            from: MailAddress(name: "Alice", email: "alice@x.com"),
            subject: subject,
            date: "",
            messageID: messageID
        )
    }

    private func needsInfoDraft(missing: [String]) -> Draft {
        Draft(
            id: 5,
            sourceUIDValidity: 1,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: "Budget?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@x.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@x.com>",
            replySubject: "Re: Budget?",
            body: "",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            needsInfo: DraftNeedsInfo(summary: "I need the figure only you have.", missing: missing)
        )
    }

    private func makeAppState(llm: LLMProviding) -> (AppState, SearchStubMailProvider) {
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
            sendBehavior: SendBehavior.saveAsDraft.rawValue,
            sendDelaySeconds: 0
        ))
        let provider = SearchStubMailProvider(
            threadResult: MailSearchResult(
                messages: [message(id: 5, subject: "Budget?", messageID: "<orig@x.com>")],
                totalMatches: 1,
                offset: 0,
                hasMore: false
            )
        )
        provider.bodyResult = .success(Data("Can you approve the Q3 budget?".utf8))
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        return (appState, provider)
    }

    private func round(_ question: String, _ response: String) -> UserSuppliedFacts {
        UserSuppliedFacts(answers: [.init(question: question, response: response)])
    }

    // MARK: - Second NEEDS_INFO keeps answers + surfaces the escape

    func testSecondNeedsInfoKeepsAnswersAndSurfacesWriteItYourself() async throws {
        let llm = ScriptedLLMProvider(responses: [
            "NEEDS_INFO: I still need one more thing.\n- Who approved it?",
            "NEEDS_INFO: one more still.\n- What is the deadline?"
        ])
        let (appState, _) = makeAppState(llm: llm)
        try appState.enqueuePendingDraft(needsInfoDraft(missing: ["What is the budget?"]))
        let first = try XCTUnwrap(appState.pendingDrafts.first)

        // Round 1: answer the seeded question.
        await appState.redraftPendingDraftWithAnswers(first, round: round("What is the budget?", "$50k"))

        let afterRound1 = try XCTUnwrap(appState.pendingDrafts.first)
        XCTAssertEqual(afterRound1.needsInfo?.missing, ["Who approved it?"], "new questions shown")
        XCTAssertEqual(afterRound1.userSuppliedFacts?.answers.first?.response, "$50k", "answer preserved")
        XCTAssertEqual(afterRound1.answeredRedraftFailures, 1)
        XCTAssertFalse(afterRound1.shouldOfferWriteItYourself, "escape not offered after only one failure")
        XCTAssertTrue(try XCTUnwrap(llm.requests.first?.messages.first?.content).contains("$50k"),
                      "the re-draft prompt carried the user's answer")

        // Round 2: answer the new question. Prior answer must not be lost.
        await appState.redraftPendingDraftWithAnswers(afterRound1, round: round("Who approved it?", "Finance"))

        let afterRound2 = try XCTUnwrap(appState.pendingDrafts.first)
        let responses = Set((afterRound2.userSuppliedFacts?.answers ?? []).map(\.response))
        XCTAssertEqual(responses, ["$50k", "Finance"], "both rounds of answers are retained")
        XCTAssertEqual(afterRound2.answeredRedraftFailures, 2)
        XCTAssertTrue(afterRound2.shouldOfferWriteItYourself, "escape offered after the second failure")
        let secondPrompt = try XCTUnwrap(llm.requests.last?.messages.first?.content)
        XCTAssertTrue(secondPrompt.contains("$50k") && secondPrompt.contains("Finance"),
                      "accumulated facts are re-injected on every re-draft")
    }

    // MARK: - A successful re-draft clears the flag but keeps the facts

    func testSuccessfulRedraftClearsNeedsInfoAndRetainsFacts() async throws {
        let llm = ScriptedLLMProvider(responses: ["Approved — the $50k budget is good to go."])
        let (appState, _) = makeAppState(llm: llm)
        try appState.enqueuePendingDraft(needsInfoDraft(missing: ["What is the budget?"]))
        let first = try XCTUnwrap(appState.pendingDrafts.first)

        await appState.redraftPendingDraftWithAnswers(first, round: round("What is the budget?", "$50k"))

        let redrafted = try XCTUnwrap(appState.pendingDrafts.first)
        XCTAssertNil(redrafted.needsInfo, "a usable reply clears the needs-info flag")
        XCTAssertFalse(redrafted.isFlagged)
        XCTAssertTrue(redrafted.body.contains("Approved"))
        XCTAssertEqual(redrafted.userSuppliedFacts?.answers.first?.response, "$50k", "facts retained on the draft")
    }

    // MARK: - Re-draft stays disabled with no answers

    func testRedraftWithNoAnswersDoesNotCallTheModel() async throws {
        let llm = ScriptedLLMProvider(responses: ["should never be used"])
        let (appState, _) = makeAppState(llm: llm)
        try appState.enqueuePendingDraft(needsInfoDraft(missing: ["What is the budget?"]))
        let first = try XCTUnwrap(appState.pendingDrafts.first)

        await appState.redraftPendingDraftWithAnswers(
            first,
            round: UserSuppliedFacts(answers: [.init(question: "What is the budget?", response: "   ")])
        )

        XCTAssertEqual(llm.completeCount, 0, "a blank answer never triggers a re-draft")
        XCTAssertNotNil(appState.approvalError)
        XCTAssertNotNil(appState.pendingDrafts.first?.needsInfo, "the draft stays flagged")
    }

    // MARK: - Write-it-yourself escape

    func testWriteItYourselfSeedsBodyWithAnswersAndClearsFlag() async throws {
        let (appState, _) = makeAppState(llm: ScriptedLLMProvider(responses: []))
        var draft = needsInfoDraft(missing: ["Who approved it?"])
        draft.userSuppliedFacts = UserSuppliedFacts(
            answers: [.init(question: "What is the budget?", response: "$50k")]
        )
        draft.answeredRedraftCount = 2
        try appState.enqueuePendingDraft(draft)
        let queued = try XCTUnwrap(appState.pendingDrafts.first)

        let result = appState.writeReplyYourself(queued, currentRound: round("Who approved it?", "Finance"))

        let updated = try XCTUnwrap(result)
        XCTAssertNil(updated.needsInfo, "the escape converts the draft to a normal editable reply")
        XCTAssertFalse(updated.isFlagged)
        XCTAssertTrue(updated.body.contains("$50k"), "prior answer seeded into the body")
        XCTAssertTrue(updated.body.contains("Finance"), "the latest typed answer seeded into the body")
    }

    // MARK: - Privacy: answers never reach the activity history

    func testSuppliedFactsNeverAppearInActivityHistory() async throws {
        let llm = ScriptedLLMProvider(responses: ["NEEDS_INFO: more please.\n- Who approved it?"])
        let (appState, _) = makeAppState(llm: llm)
        try appState.enqueuePendingDraft(needsInfoDraft(missing: ["What is the budget?"]))
        let first = try XCTUnwrap(appState.pendingDrafts.first)

        await appState.redraftPendingDraftWithAnswers(first, round: round("What is the budget?", "$50k-secret"))

        let encoded = try JSONEncoder().encode(appState.activityEvents)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("$50k-secret"), "supplied facts must never be written to the activity log")
    }
}
