import XCTest
@testable import Sentwise

/// Records the requests a generator sends and replays canned responses so prompt
/// assembly and long-transcript summarization are testable without a network.
private final class RequestRecorder: @unchecked Sendable {
    private(set) var requests: [LLMRequest] = []
    var responses: [String]
    var defaultResponse: String

    init(responses: [String] = [], defaultResponse: String = "Follow-up body.") {
        self.responses = responses
        self.defaultResponse = defaultResponse
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        requests.append(request)
        let text = responses.isEmpty ? defaultResponse : responses.removeFirst()
        return LLMResponse(text: text)
    }
}

final class FollowUpGeneratorTests: XCTestCase {

    func testSinglePassDraftsFromFullTranscript() async throws {
        let recorder = RequestRecorder(defaultResponse: "Hi team,\n\nGreat call today.")
        let transcript = ParsedTranscript(text: "Marcus: Let's ship Friday.", hasSpeakerLabels: true)

        let body = try await FollowUpGenerator().makeFollowUp(
            transcript: transcript,
            voiceProfile: nil,
            model: "test-model",
            complete: recorder.complete
        )

        XCTAssertEqual(body, "Hi team,\n\nGreat call today.")
        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertTrue(request.system?.contains("follow-up email") ?? false)
        XCTAssertTrue(request.messages.first?.content.contains("Marcus: Let's ship Friday.") ?? false)
        XCTAssertTrue(request.messages.first?.content.contains("labels each speaker") ?? false)
    }

    func testInjectsUserSuppliedFactsBlockForFollowUps() async throws {
        // The answer-in-place facts mechanism (item 85) is generator-agnostic: a
        // follow-up re-draft carrying facts injects the same authoritative block.
        let recorder = RequestRecorder()
        let transcript = ParsedTranscript(text: "Marcus: Let's ship soon.", hasSpeakerLabels: true)
        let facts = UserSuppliedFacts(
            answers: [.init(question: "Ship date?", response: "Aug 6")],
            additional: "Loop in Priya."
        )

        _ = try await FollowUpGenerator().makeFollowUp(
            transcript: transcript,
            voiceProfile: nil,
            model: "m",
            userSuppliedFacts: facts,
            complete: recorder.complete
        )

        let content = try XCTUnwrap(recorder.requests.first?.messages.first?.content)
        XCTAssertTrue(content.contains("Facts supplied by the user (authoritative"))
        XCTAssertTrue(content.contains("Ship date?: Aug 6"))
        XCTAssertTrue(content.contains("Loop in Priya."))
        XCTAssertTrue(content.contains("do NOT ask the user for them again"))
    }

    func testUnlabeledTranscriptGetsUnlabeledSpeakerGuidance() async throws {
        let recorder = RequestRecorder()
        let transcript = ParsedTranscript(text: "We agreed to ship Friday.", hasSpeakerLabels: false)

        _ = try await FollowUpGenerator().makeFollowUp(
            transcript: transcript,
            voiceProfile: nil,
            model: "m",
            complete: recorder.complete
        )

        let content = try XCTUnwrap(recorder.requests.first?.messages.first?.content)
        XCTAssertTrue(content.contains("not labeled by speaker"))
    }

    func testVoiceProfileIsInjectedIntoSystemPrompt() async throws {
        let recorder = RequestRecorder()
        let profile = VoiceProfile(
            greeting: "Hey {first name},",
            signOff: "Cheers,\nMarcus",
            formality: "casual",
            tone: "warm",
            averageLength: "short",
            commonPhrases: ["circle back"],
            summary: "warm and brief",
            sampleCount: 20,
            generatedAt: Date()
        )
        let transcript = ParsedTranscript(text: "Marcus: ship it.", hasSpeakerLabels: true)

        _ = try await FollowUpGenerator().makeFollowUp(
            transcript: transcript,
            voiceProfile: profile,
            model: "m",
            complete: recorder.complete
        )

        let system = try XCTUnwrap(recorder.requests.first?.system)
        XCTAssertTrue(system.contains("circle back"))
        XCTAssertTrue(system.contains("Cheers,"))
    }

    func testLongTranscriptSummarizesBeforeDrafting() async throws {
        let recorder = RequestRecorder(defaultResponse: "- summary bullet")
        // Force summarization: tiny thresholds turn a modest transcript "long".
        var generator = FollowUpGenerator()
        generator.maxSinglePassChars = 40
        generator.maxChunkChars = 30

        let longText = (1...12)
            .map { "Speaker \($0 % 2): line number \($0) of the discussion" }
            .joined(separator: "\n")
        let transcript = ParsedTranscript(text: longText, hasSpeakerLabels: true)

        let body = try await generator.makeFollowUp(
            transcript: transcript,
            voiceProfile: nil,
            model: "m",
            complete: recorder.complete
        )

        XCTAssertFalse(body.isEmpty)
        // More than one call means summarization happened (>=1 summary + 1 draft).
        XCTAssertGreaterThan(recorder.requests.count, 1)
        // Every request but the last is a summarization pass.
        let draftRequest = try XCTUnwrap(recorder.requests.last)
        XCTAssertTrue(draftRequest.messages.first?.content.contains("Call summary:") ?? false)
        let summaryRequest = try XCTUnwrap(recorder.requests.first)
        XCTAssertTrue(summaryRequest.system?.contains("condensing a call transcript") ?? false)
    }

    func testLongTranscriptReducesCombinedSummaryBeforeDrafting() async throws {
        let recorder = RequestRecorder(
            responses: Array(repeating: String(repeating: "A", count: 80), count: 4),
            defaultResponse: "short"
        )
        var generator = FollowUpGenerator()
        generator.maxSinglePassChars = 100
        generator.maxChunkChars = 50

        let transcript = ParsedTranscript(
            text: String(repeating: "transcript ", count: 30),
            hasSpeakerLabels: false
        )

        _ = try await generator.makeFollowUp(
            transcript: transcript,
            voiceProfile: nil,
            model: "m",
            complete: recorder.complete
        )

        let draftContent = try XCTUnwrap(recorder.requests.last?.messages.first?.content)
        let summary = try XCTUnwrap(draftContent.components(separatedBy: "Call summary:\n\n").last)
        XCTAssertLessThanOrEqual(summary.count, generator.maxSinglePassChars)
        XCTAssertGreaterThan(recorder.requests.count, 5)
    }

    func testEmptyTranscriptThrows() async {
        let recorder = RequestRecorder()
        let transcript = ParsedTranscript(text: "   ", hasSpeakerLabels: false)
        do {
            _ = try await FollowUpGenerator().makeFollowUp(
                transcript: transcript,
                voiceProfile: nil,
                model: "m",
                complete: recorder.complete
            )
            XCTFail("Expected emptyDraft")
        } catch {
            XCTAssertEqual(error as? DraftError, .emptyDraft)
        }
    }

    func testEmptyModelOutputThrows() async {
        let recorder = RequestRecorder(defaultResponse: "   \n  ")
        let transcript = ParsedTranscript(text: "Marcus: ship it.", hasSpeakerLabels: true)
        do {
            _ = try await FollowUpGenerator().makeFollowUp(
                transcript: transcript,
                voiceProfile: nil,
                model: "m",
                complete: recorder.complete
            )
            XCTFail("Expected emptyDraft")
        } catch {
            XCTAssertEqual(error as? DraftError, .emptyDraft)
        }
    }
}
