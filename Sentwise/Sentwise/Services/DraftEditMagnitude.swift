import Foundation

/// A pure, cheap measure of how much a user rewrote a draft before approving it
/// (item 83, Phase 1). It quantifies item 19's captured `originalBody` vs. the
/// final `body` as a single normalized number the feedback store can learn from.
///
/// **Metric (documented, fixed):** the normalized character-level Levenshtein
/// (edit-distance) ratio.
///
///   `magnitude = levenshtein(a, b) / max(a.count, b.count)`
///
/// where `a` and `b` are the *normalized* original and final bodies:
/// leading/trailing whitespace trimmed and every internal run of whitespace
/// (spaces, tabs, newlines) collapsed to a single space. Normalization means pure
/// reflow/spacing changes register as ~zero magnitude, so the signal tracks
/// substantive content edits rather than formatting churn. The result is clamped
/// to `0...1`: `0` = identical after normalization, `1` = a complete rewrite.
///
/// Character-level (over changed-line fraction) is deliberate: a one-word fix
/// inside a long paragraph should read as a small edit, not a whole changed line.
/// Cost is `O(a.count * b.count)` with `O(min)` memory (two-row DP); draft bodies
/// are short and this runs once per approval, so it is cheap in practice.
enum DraftEditMagnitude {

    /// The normalized edit magnitude in `0...1`. Both empty (after normalization)
    /// returns `0`.
    static func ratio(original: String, final: String) -> Double {
        let a = Array(normalize(original))
        let b = Array(normalize(final))
        if a.isEmpty && b.isEmpty { return 0 }
        let distance = levenshtein(a, b)
        let denominator = max(a.count, b.count)
        guard denominator > 0 else { return 0 }
        let ratio = Double(distance) / Double(denominator)
        return min(1, max(0, ratio))
    }

    /// Trims and collapses whitespace runs so formatting-only differences don't
    /// inflate the magnitude.
    static func normalize(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }

    /// Character-level Levenshtein distance with two-row dynamic programming.
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitutionCost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,          // deletion
                    current[j - 1] + 1,       // insertion
                    previous[j - 1] + substitutionCost // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
