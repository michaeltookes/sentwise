import Foundation

/// Errors specific to voice-profile learning.
enum VoiceProfileError: Error, Equatable {
    /// No usable Sent messages were found to learn from.
    case noSamples
    /// The model's response couldn't be parsed into a profile.
    case invalidResponse(String)
}

/// Derives a `VoiceProfile` from Sent-message bodies by prompting an LLM.
///
/// Pure and network-free: the caller injects a `complete` closure (backed by
/// `LLMProviding` in the app, a stub in tests), so prompt construction, sample
/// cleaning, and response parsing are all unit-testable.
struct VoiceProfiler {
    typealias Complete = (LLMRequest) async throws -> LLMResponse

    /// Most samples to send (bounds token cost).
    var maxSamples = 12
    /// Per-sample character cap (bounds token cost; trims long threads).
    var maxCharsPerSample = 1500

    func makeProfile(
        fromSentBodies bodies: [String],
        model: String,
        now: Date,
        complete: Complete
    ) async throws -> VoiceProfile {
        let samples = Self.cleanedSamples(
            from: bodies,
            maxSamples: maxSamples,
            maxChars: maxCharsPerSample
        )
        guard !samples.isEmpty else { throw VoiceProfileError.noSamples }

        let request = LLMRequest(
            system: Self.systemPrompt,
            messages: [LLMMessage(role: .user, content: Self.userPrompt(samples: samples))],
            model: model,
            maxTokens: 1024,
            temperature: 0.3
        )

        let response = try await complete(request)
        let parsed = try Self.parse(response.text)
        return VoiceProfile(
            greeting: VoiceProfile.normalizedGreeting(parsed.greeting),
            signOff: parsed.signOff,
            formality: parsed.formality,
            tone: parsed.tone,
            averageLength: parsed.averageLength,
            commonPhrases: parsed.commonPhrases,
            summary: parsed.summary,
            sampleCount: samples.count,
            generatedAt: now
        )
    }

    // MARK: - Sample preparation

    /// Cleans raw bodies into usable writing samples: strips quoted reply
    /// history, trims, drops empties, truncates, and caps the count.
    static func cleanedSamples(from bodies: [String], maxSamples: Int, maxChars: Int) -> [String] {
        var samples: [String] = []
        for body in bodies {
            let stripped = strippingQuotedReply(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            samples.append(String(stripped.prefix(maxChars)))
            if samples.count == maxSamples { break }
        }
        return samples
    }

    /// Truncates at the first quoted-reply marker so profiling sees only what
    /// the user actually wrote, not the message they replied to. Delegates to
    /// the shared `EmailThreadParser` so quote detection has one source of truth.
    static func strippingQuotedReply(_ text: String) -> String {
        EmailThreadParser.split(text).latest
    }

    // MARK: - Prompt

    private static let systemPrompt = """
    You analyze a person's outgoing emails and produce a concise, reusable \
    profile of their writing voice. Respond with ONLY a JSON object — no prose, \
    no code fences — matching exactly these keys: greeting (string), signOff \
    (string), formality (string), tone (string), averageLength (string), \
    commonPhrases (array of strings, up to 6), summary (string, 2-3 sentences). \
    For greeting, give only the form, never a person's name: write "Hi <first name>," \
    rather than "Hi Dana,". Base every field only on how the person writes. If a field is unclear, use \
    an empty string or empty array.
    """

    private static func userPrompt(samples: [String]) -> String {
        let joined = samples
            .enumerated()
            .map { "Email \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n---\n\n")
        return "Here are \(samples.count) of my sent emails:\n\n\(joined)"
    }

    // MARK: - Parsing

    private struct ProfileDTO: Decodable {
        var greeting = ""
        var signOff = ""
        var formality = ""
        var tone = ""
        var averageLength = ""
        var commonPhrases: [String] = []
        var summary = ""

        enum CodingKeys: String, CodingKey {
            case greeting, signOff, formality, tone, averageLength, commonPhrases, summary
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            greeting = try container.decodeIfPresent(String.self, forKey: .greeting) ?? ""
            signOff = try container.decodeIfPresent(String.self, forKey: .signOff) ?? ""
            formality = try container.decodeIfPresent(String.self, forKey: .formality) ?? ""
            tone = try container.decodeIfPresent(String.self, forKey: .tone) ?? ""
            averageLength = try container.decodeIfPresent(String.self, forKey: .averageLength) ?? ""
            commonPhrases = try container.decodeIfPresent([String].self, forKey: .commonPhrases) ?? []
            summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        }
    }

    private static func parse(_ text: String) throws -> ProfileDTO {
        guard let json = extractJSONObject(from: text) else {
            throw VoiceProfileError.invalidResponse("No JSON object found in the model's reply.")
        }
        do {
            return try JSONDecoder().decode(ProfileDTO.self, from: Data(json.utf8))
        } catch {
            throw VoiceProfileError.invalidResponse("Couldn't decode the profile. (\(error))")
        }
    }

    /// Extracts the outermost `{…}` object, tolerating code fences or stray
    /// prose the model may add despite instructions.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(text[start...end])
    }
}
