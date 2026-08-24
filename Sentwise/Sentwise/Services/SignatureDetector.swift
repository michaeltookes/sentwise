import Foundation

/// Heuristically extracts a user's recurring email signature from a sample of
/// their Sent messages (item 24).
///
/// Pure and network-free: the caller (`AppState.suggestSignatureFromSentMail`)
/// fetches the Sent bodies via the existing IMAP path and hands them here, so the
/// heuristics are fully unit-testable. Quote detection is delegated to the shared
/// `EmailThreadParser` so a reply's quoted history never leaks into the sample.
enum SignatureDetector {

    /// Recognized sign-off openers (compared case-insensitively, with trailing
    /// punctuation stripped) that mark the top of a signature block when no
    /// explicit `--` delimiter is present.
    static let signOffCues: Set<String> = [
        "best", "best regards", "regards", "kind regards", "warm regards",
        "thanks", "thank you", "thanks so much", "many thanks", "thanks again",
        "cheers", "sincerely", "warmly", "yours", "yours truly", "yours sincerely",
        "talk soon", "speak soon", "all the best", "take care", "cordially",
        "respectfully", "with gratitude", "much appreciated", "appreciated"
    ]

    /// Most trailing lines to treat as a candidate signature block. Bounds a
    /// stray "thanks" mid-body from swallowing a long paragraph.
    static let maxSignatureLines = 10
    /// Character cap on a candidate block, another guard against runaway matches.
    static let maxSignatureChars = 600

    /// Extracts the signature block that recurs across the sampled Sent bodies,
    /// or `nil` when no consistent signature can be found.
    ///
    /// With two or more usable samples, a block must repeat in at least
    /// `minimumRepeats` messages to count as "the user's signature". With a
    /// single usable sample, a delimiter- or sign-off-anchored candidate is
    /// accepted on its own (there's nothing to corroborate against).
    static func detect(fromSentBodies bodies: [String], minimumRepeats: Int = 2) -> String? {
        let freshBodies = bodies
            .map(freshText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let candidates = freshBodies
            .compactMap(signatureCandidate)
        guard !candidates.isEmpty else { return nil }

        if freshBodies.count == 1, candidates.count == 1 {
            return candidates[0].display
        }

        var counts: [String: (display: String, count: Int)] = [:]
        for candidate in candidates {
            let existing = counts[candidate.key]
            counts[candidate.key] = (existing?.display ?? candidate.display, (existing?.count ?? 0) + 1)
        }
        let best = counts.values.max { lhs, rhs in lhs.count < rhs.count }
        guard let best, best.count >= minimumRepeats else { return nil }
        guard counts.values.filter({ $0.count == best.count }).count == 1 else { return nil }
        return best.display
    }

    // MARK: - Candidate extraction

    /// A signature candidate: `display` is the cleaned text to show/return;
    /// `key` is a normalized form used only to group repeats.
    struct Candidate: Equatable {
        var display: String
        var key: String
    }

    /// Strips any quoted reply history so only what the user actually wrote is
    /// considered.
    static func freshText(_ body: String) -> String {
        EmailThreadParser.split(body).latest
    }

    /// Extracts the trailing signature block from one message's fresh text, or
    /// `nil` when it has no delimiter- or sign-off-anchored trailing block.
    static func signatureCandidate(_ text: String) -> Candidate? {
        let lines = trimmedTrailingBlankLines(text.components(separatedBy: "\n"))
        guard !lines.isEmpty else { return nil }

        guard let block = delimitedBlock(lines) ?? signOffBlock(lines) else { return nil }
        let cleaned = trimmedTrailingBlankLines(trimmedLeadingBlankLines(block))
            .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingTrailingWhitespace() }
        guard !cleaned.isEmpty, cleaned.count <= maxSignatureLines else { return nil }

        let display = cleaned.joined(separator: "\n")
        guard display.count <= maxSignatureChars else { return nil }
        let key = cleaned
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .joined(separator: "\n")
        return Candidate(display: display, key: key)
    }

    /// The block after the last standard signature delimiter line (`--` or
    /// `-- `), if any exists.
    private static func delimitedBlock(_ lines: [String]) -> [String]? {
        let markerIndex = lines.lastIndex { line in
            line.trimmingCharacters(in: .whitespaces) == "--"
        }
        guard let markerIndex, markerIndex + 1 < lines.count else { return nil }
        return Array(lines[(markerIndex + 1)...])
    }

    /// The block from the last sign-off cue line to the end, searching only the
    /// final window of lines so a mid-body "thanks" can't anchor a signature.
    private static func signOffBlock(_ lines: [String]) -> [String]? {
        let windowStart = max(0, lines.count - maxSignatureLines)
        for index in stride(from: lines.count - 1, through: windowStart, by: -1) where isSignOff(lines[index]) {
            return Array(lines[index...])
        }
        return nil
    }

    /// Whether a line is a recognized sign-off opener (e.g. "Best," / "Thanks!").
    static func isSignOff(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!;:-"))
            .lowercased()
        return signOffCues.contains(normalized)
    }

    // MARK: - Line helpers

    private static func trimmedTrailingBlankLines(_ lines: [String]) -> [String] {
        var copy = lines
        while let last = copy.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            copy.removeLast()
        }
        return copy
    }

    private static func trimmedLeadingBlankLines(_ lines: [String]) -> [String] {
        var copy = lines
        while let first = copy.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            copy.removeFirst()
        }
        return copy
    }
}

private extension String {
    /// Drops only trailing spaces/tabs, preserving intentional leading indent.
    func trimmingTrailingWhitespace() -> String {
        var slice = Substring(self)
        while let last = slice.last, last == " " || last == "\t" {
            slice = slice.dropLast()
        }
        return String(slice)
    }
}
