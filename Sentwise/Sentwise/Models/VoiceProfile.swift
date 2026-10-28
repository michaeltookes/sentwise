import Foundation

/// A reusable summary of the user's writing voice, derived from their Sent mail
/// and injected into every draft-generation prompt (item 7).
struct VoiceProfile: Codable, Equatable {
    /// Typical opener in placeholder form, e.g. `"Hi <first name>,"`. A learned
    /// greeting never carries a personal name (item 138): see `normalizedGreeting`.
    var greeting: String
    /// Typical closing, e.g. `"Best,\nMichael"`.
    var signOff: String
    /// Short descriptor of formality, e.g. `"casual but professional"`.
    var formality: String
    /// Short descriptor of tone, e.g. `"warm, direct"`.
    var tone: String
    /// Typical length, e.g. `"short — 2-4 sentences"`.
    var averageLength: String
    /// Recurring phrasings the user reaches for.
    var commonPhrases: [String]
    /// A human-readable paragraph shown in Settings.
    var summary: String
    /// How many Sent messages the profile was derived from.
    var sampleCount: Int
    /// When the profile was generated.
    var generatedAt: Date

    /// The placeholder a normalised greeting uses for the recipient's first name.
    static let firstNamePlaceholder = "<first name>"

    private static let salutationWords: Set<String> = [
        "hi", "hello", "hey", "dear", "greetings", "morning", "afternoon", "evening", "howdy", "hiya", "thanks"
    ]
    /// Words that follow a salutation without being a personal name.
    private static let nonNameWords: Set<String> = [
        "there", "all", "team", "everyone", "everybody", "folks", "friends", "both", "guys", "y'all",
        "again", "and", "&", "name", "first", "recipient", "colleague", "colleagues", "sir", "madam"
    ]

    /// Rewrites a greeting so it carries the placeholder instead of a personal
    /// name: `"Hi Michael,"` becomes `"Hi <first name>,"`, `"Hey Dana -"` becomes
    /// `"Hey <first name> -"`, `"Hi {first name},"` becomes `"Hi <first name>,"`.
    /// Name-free greetings (`"Hello,"`, `"Hi team,"`) and already-normalised ones
    /// are returned unchanged, so applying it twice equals applying it once.
    static func normalizedGreeting(_ greeting: String, knownNames: [String] = []) -> String {
        var text = greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        for variant in ["{first name}", "{First name}", "{firstname}", "[first name]", "[First Name]",
                        "{{first_name}}", "{first_name}", "<First Name>", "<firstname>", "<Firstname>"] {
            text = text.replacingOccurrences(of: variant, with: firstNamePlaceholder)
        }
        if text.contains(firstNamePlaceholder) { return text }

        // Split the greeting into word tokens and trailing punctuation.
        let nsText = text as NSString
        let pattern = #"[\p{L}][\p{L}'’.\-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        guard let start = nameStartIndex(in: matches, text: nsText, knownNames: knownNames) else { return text }
        // The name may span several words ("Ms. Reyes", "Dana Reyes"): replace the whole
        // run of words that are separated only by spaces.
        var end = start
        while end + 1 < matches.count {
            let gap = NSRange(
                location: NSMaxRange(matches[end].range),
                length: matches[end + 1].range.location - NSMaxRange(matches[end].range)
            )
            guard nsText.substring(with: gap) == " ",
                  isPersonalName(nsText.substring(with: matches[end + 1].range)) else { break }
            end += 1
        }
        let range = NSRange(
            location: matches[start].range.location,
            length: NSMaxRange(matches[end].range) - matches[start].range.location
        )
        return nsText.replacingCharacters(in: range, with: firstNamePlaceholder)
    }

    /// Index of the first word of the personal name in a greeting's word matches.
    private static func nameStartIndex(
        in matches: [NSTextCheckingResult],
        text: NSString,
        knownNames: [String]
    ) -> Int? {
        let words = matches.map { text.substring(with: $0.range) }
        let first = words[0].lowercased()
        if salutationWords.contains(first) {
            return words.count > 1 && isPersonalName(words[1]) ? 1 : nil
        }
        if first == "good", words.count > 2 {
            // "Good morning Dana,"
            return salutationWords.contains(words[1].lowercased()) && isPersonalName(words[2]) ? 2 : nil
        }
        // A bare "Dana," opener is a name only with evidence (a known name); a standalone
        // word such as "Bonjour," or "Welcome," is left alone.
        let known = Set(knownNames.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        return words.count == 1 && known.contains(words[0].lowercased()) && isPersonalName(words[0]) ? 0 : nil
    }

    private static func isPersonalName(_ word: String) -> Bool {
        let lowered = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        guard lowered.count >= 2, !nonNameWords.contains(lowered), !salutationWords.contains(lowered) else {
            return false
        }
        return word.first?.isUppercase ?? false
    }

    /// A copy whose greeting is in placeholder form. Idempotent; used when a
    /// profile is learned and when a stored profile is loaded (item 138).
    func withNormalizedGreeting(knownNames: [String] = []) -> VoiceProfile {
        var copy = self
        copy.greeting = Self.normalizedGreeting(greeting, knownNames: knownNames)
        return copy
    }

    /// Renders the profile as instructions for injection into a draft prompt.
    /// The greeting is always rendered in placeholder form; when the recipient's
    /// first name is known it is substituted here, at draft time.
    func promptBlock(recipientFirstName: String? = nil, omitNameWhenUnknown: Bool = false) -> String {
        var lines = ["The reply must match the sender's writing voice:"]
        let greeting = Self.normalizedGreeting(self.greeting)
        if !greeting.isEmpty {
            if let name = recipientFirstName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                lines.append("- Greeting: " + greeting.replacingOccurrences(of: Self.firstNamePlaceholder, with: name))
            } else if greeting.contains(Self.firstNamePlaceholder), omitNameWhenUnknown {
                lines.append("- Greeting: \(greeting) (no recipient name is known: drop \(Self.firstNamePlaceholder) "
                    + "and write the greeting without a name, for example \"Hi,\"; never invent a name)")
            } else if greeting.contains(Self.firstNamePlaceholder) {
                lines.append("- Greeting: \(greeting) (\(Self.firstNamePlaceholder) stands for the first name "
                    + "of the person the email is addressed to; never use any other name)")
            } else {
                lines.append("- Greeting: \(greeting)")
            }
        }
        if !signOff.isEmpty { lines.append("- Sign-off: \(signOff)") }
        if !formality.isEmpty { lines.append("- Formality: \(formality)") }
        if !tone.isEmpty { lines.append("- Tone: \(tone)") }
        if !averageLength.isEmpty { lines.append("- Typical length: \(averageLength)") }
        if !commonPhrases.isEmpty {
            lines.append("- Recurring phrases: \(commonPhrases.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }
}
