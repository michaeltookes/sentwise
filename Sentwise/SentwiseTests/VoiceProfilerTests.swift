import XCTest
@testable import Sentwise

final class VoiceProfilerTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func profileJSON() -> String {
        #"""
        {"greeting":"Hi there,","signOff":"Best,\nMichael","formality":"casual but professional",
         "tone":"warm, direct","averageLength":"short — 2-4 sentences",
         "commonPhrases":["Sounds good","Let me know"],"summary":"Writes briefly and warmly."}
        """#
    }

    func testMakeProfileParsesResponseAndStampsMetadata() async throws {
        var captured: LLMRequest?
        let profiler = VoiceProfiler()

        let profile = try await profiler.makeProfile(
            fromSentBodies: ["Hi there,\n\nSounds good.\n\nBest,\nMichael"],
            model: "claude-sonnet-4-6",
            now: fixedDate
        ) { request in
            captured = request
            return LLMResponse(text: self.profileJSON())
        }

        XCTAssertEqual(profile.greeting, "Hi there,")
        XCTAssertEqual(profile.signOff, "Best,\nMichael")
        XCTAssertEqual(profile.tone, "warm, direct")
        XCTAssertEqual(profile.commonPhrases, ["Sounds good", "Let me know"])
        XCTAssertEqual(profile.summary, "Writes briefly and warmly.")
        XCTAssertEqual(profile.sampleCount, 1)
        XCTAssertEqual(profile.generatedAt, fixedDate)
        XCTAssertEqual(captured?.model, "claude-sonnet-4-6")
        XCTAssertTrue(captured?.messages.first?.content.contains("Sounds good") ?? false)
    }

    func testMakeProfileSendsVoiceLearningPurpose() async throws {
        var captured: LLMRequest?
        _ = try await VoiceProfiler().makeProfile(
            fromSentBodies: ["Hi there,\n\nSounds good.\n\nBest,\nMichael"],
            model: "claude-sonnet-4-6",
            now: fixedDate
        ) { request in
            captured = request
            return LLMResponse(text: self.profileJSON())
        }
        XCTAssertEqual(captured?.purpose, .voiceLearning)
        XCTAssertEqual(LLMRequest(messages: [], model: "m").purpose, .draft)
    }

    func testMakeProfileToleratesCodeFencedJSON() async throws {
        let profiler = VoiceProfiler()
        let fenced = "Here you go:\n```json\n\(profileJSON())\n```"

        let profile = try await profiler.makeProfile(
            fromSentBodies: ["Some real content here."],
            model: "m",
            now: fixedDate
        ) { _ in LLMResponse(text: fenced) }

        XCTAssertEqual(profile.greeting, "Hi there,")
    }

    func testMakeProfileThrowsWhenNoUsableSamples() async {
        let profiler = VoiceProfiler()
        do {
            _ = try await profiler.makeProfile(
                fromSentBodies: ["   ", "\n\n"],
                model: "m",
                now: fixedDate
            ) { _ in LLMResponse(text: self.profileJSON()) }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceProfileError, .noSamples)
        }
    }

    func testMakeProfileThrowsOnUnparseableResponse() async {
        let profiler = VoiceProfiler()
        do {
            _ = try await profiler.makeProfile(
                fromSentBodies: ["Real content."],
                model: "m",
                now: fixedDate
            ) { _ in LLMResponse(text: "sorry, I can't do that") }
            XCTFail("expected an error")
        } catch {
            guard case .invalidResponse = error as? VoiceProfileError else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    func testStrippingQuotedReplyRemovesHistory() {
        let text = """
        Thanks, that works for me.

        On Mon, Jan 1, 2026 at 9:00 AM Alice <alice@x.com> wrote:
        > Are you free Monday?
        > Let me know.
        """
        XCTAssertEqual(VoiceProfiler.strippingQuotedReply(text), "Thanks, that works for me.\n")
    }

    func testCleanedSamplesTruncatesAndCapsCount() {
        let long = String(repeating: "a", count: 5000)
        let bodies = Array(repeating: long, count: 30)

        let samples = VoiceProfiler.cleanedSamples(from: bodies, maxSamples: 5, maxChars: 100)

        XCTAssertEqual(samples.count, 5)
        XCTAssertTrue(samples.allSatisfy { $0.count == 100 })
    }
}
