import XCTest
@testable import Sentwise

final class DraftGeneratorTests: XCTestCase {

    private func context() -> ReplyContext {
        ReplyContext(
            senderName: "Alice",
            senderEmail: "alice@example.com",
            subject: "Lunch Thursday?",
            body: "Are you free for lunch Thursday at noon?"
        )
    }

    private func profile() -> VoiceProfile {
        VoiceProfile(
            greeting: "Hey,", signOff: "Cheers,\nM", formality: "casual", tone: "warm",
            averageLength: "short", commonPhrases: ["Sounds good"], summary: "Brief and warm.",
            sampleCount: 5, generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testBuildsPromptWithIncomingMessageAndVoiceProfile() async throws {
        var captured: LLMRequest?
        let generator = DraftGenerator()

        _ = try await generator.makeDraft(
            replyingTo: context(),
            voiceProfile: profile(),
            model: "claude-sonnet-4-6"
        ) { request in
            captured = request
            return LLMResponse(text: "Sounds good — see you Thursday!")
        }

        let system = try XCTUnwrap(captured?.system)
        XCTAssertTrue(system.contains("Greeting: Hey,"), "voice profile must be injected")
        let user = try XCTUnwrap(captured?.messages.first?.content)
        XCTAssertTrue(user.contains("Alice <alice@example.com>"))
        XCTAssertTrue(user.contains("Lunch Thursday?"))
        XCTAssertTrue(user.contains("Are you free for lunch"))
        XCTAssertEqual(captured?.model, "claude-sonnet-4-6")
    }

    func testUsesNeutralVoiceWhenNoProfile() async throws {
        var captured: LLMRequest?
        let generator = DraftGenerator()

        _ = try await generator.makeDraft(
            replyingTo: context(),
            voiceProfile: nil,
            model: "m"
        ) { request in
            captured = request
            return LLMResponse(text: "Yes, noon works.")
        }

        XCTAssertTrue(try XCTUnwrap(captured?.system).contains("natural, concise, and professional"))
    }

    func testReturnsCleanedReplyBody() async throws {
        let generator = DraftGenerator()

        let outcome = try await generator.makeDraft(
            replyingTo: context(),
            voiceProfile: nil,
            model: "m"
        ) { _ in LLMResponse(text: "Subject: Re: Lunch Thursday?\n\nYes, noon works for me!\n") }

        XCTAssertEqual(
            outcome,
            .ready("Yes, noon works for me!"),
            "leading Subject line and whitespace stripped"
        )
    }

    /// The system prompt must tell the model how to flag a low-confidence reply,
    /// or it will fabricate one (item 13).
    func testSystemPromptInstructsTheNeedsInfoProtocol() {
        let prompt = DraftGenerator.systemPrompt(voiceProfile: nil)
        XCTAssertTrue(prompt.contains(DraftGenerator.needsInfoSentinel))
        XCTAssertTrue(prompt.contains(DraftGenerator.notReplyWorthySentinel))
        XCTAssertTrue(prompt.contains("do NOT"), "must forbid fabricating missing facts")
    }

    func testEmptyReplyThrows() async {
        let generator = DraftGenerator()

        do {
            _ = try await generator.makeDraft(
                replyingTo: context(),
                voiceProfile: nil,
                model: "m"
            ) { _ in LLMResponse(text: "   \n\n") }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DraftError, .emptyDraft)
        }
    }

    func testIncludesThreadHistoryAsContextWhenPresent() async throws {
        var captured: LLMRequest?
        let threaded = ReplyContext(
            senderName: "Alice", senderEmail: "alice@example.com", subject: "Re: Proposal",
            body: """
            Yes, let's proceed with option B.

            On Mon, Jul 21, 2026 at 9:00 AM Bob <bob@example.com> wrote:
            > Do you prefer option A or option B for the rollout?
            """
        )

        _ = try await DraftGenerator().makeDraft(replyingTo: threaded, voiceProfile: nil, model: "m") { request in
            captured = request
            return LLMResponse(text: "Great — option B it is.")
        }

        let user = try XCTUnwrap(captured?.messages.first?.content)
        XCTAssertTrue(user.contains("Reply to the latest message"))
        XCTAssertTrue(user.contains("Yes, let's proceed with option B."), "fresh message present")
        XCTAssertTrue(user.contains("Earlier in this thread"), "thread section present")
        XCTAssertTrue(user.contains("Do you prefer option A or option B"), "quoted history present, de-quoted")
        XCTAssertFalse(user.contains("> Do you prefer"), "leading quote markers stripped from context")
    }

    func testOmitsThreadSectionWhenNoHistory() async throws {
        var captured: LLMRequest?

        _ = try await DraftGenerator().makeDraft(replyingTo: context(), voiceProfile: nil, model: "m") { request in
            captured = request
            return LLMResponse(text: "ok")
        }

        XCTAssertFalse(try XCTUnwrap(captured?.messages.first?.content).contains("Earlier in this thread"))
    }

    func testLongQuotedHistoryDoesNotStarveTheFreshMessage() async throws {
        var captured: LLMRequest?
        let freshLine = "Please confirm the Thursday slot works."
        let threaded = ReplyContext(
            senderName: nil, senderEmail: "a@mail.com", subject: "Scheduling",
            body: freshLine + "\n\n> " + String(repeating: "q", count: 20_000)
        )

        _ = try await DraftGenerator().makeDraft(replyingTo: threaded, voiceProfile: nil, model: "m") { request in
            captured = request
            return LLMResponse(text: "ok")
        }

        // The fresh message survives in full even though the quoted tail is huge.
        XCTAssertTrue(try XCTUnwrap(captured?.messages.first?.content).contains(freshLine))
    }

    func testCapsThreadHistoryAtMaxThreadChars() async throws {
        var captured: LLMRequest?
        var generator = DraftGenerator()
        generator.maxThreadChars = 30
        // Use a letter absent from the prompt boilerplate so the count reflects
        // only the (capped) quoted history.
        let threaded = ReplyContext(
            senderName: nil, senderEmail: "a@mail.com", subject: "S",
            body: "Ping.\n> " + String(repeating: "z", count: 500)
        )

        _ = try await generator.makeDraft(replyingTo: threaded, voiceProfile: nil, model: "m") { request in
            captured = request
            return LLMResponse(text: "ok")
        }

        let zCount = (captured?.messages.first?.content ?? "").filter { $0 == "z" }.count
        XCTAssertEqual(zCount, 30)
    }

    func testTruncatesLongIncomingBody() async throws {
        var captured: LLMRequest?
        var generator = DraftGenerator()
        generator.maxIncomingChars = 50
        let long = ReplyContext(
            senderName: nil, senderEmail: "a@mail.com",
            subject: "Long", body: String(repeating: "x", count: 500)
        )

        _ = try await generator.makeDraft(replyingTo: long, voiceProfile: nil, model: "m") { request in
            captured = request
            return LLMResponse(text: "ok")
        }

        // The 500-char body is capped; the prompt shouldn't carry all of it.
        let xCount = (captured?.messages.first?.content ?? "").filter { $0 == "x" }.count
        XCTAssertEqual(xCount, 50)
    }
}
