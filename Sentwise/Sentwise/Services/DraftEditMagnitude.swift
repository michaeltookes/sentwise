import Foundation

/// A pure, cheap measure of how much a user rewrote a draft before approving it
/// (item 83, Phase 1). It quantifies item 19's captured `originalBody` vs. the
/// final `body` as a single normalized number the feedback store can learn from.
///
/// **Metric (documented, fixed):** the normalized character-level edit-distance
/// ratio: exact Levenshtein for ordinary drafts, with a bounded approximation for
/// unusually large pasted edits.
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
enum DraftEditMagnitude {

    static let exactDistanceCellLimit = 250_000

    /// The normalized edit magnitude in `0...1`. Both empty (after normalization)
    /// returns `0`.
    static func ratio(original: String, final: String) -> Double {
        let source = Array(normalize(original))
        let target = Array(normalize(final))
        if source.isEmpty && target.isEmpty { return 0 }
        let denominator = max(source.count, target.count)
        guard denominator > 0 else { return 0 }
        let distance = canComputeExactDistance(sourceCount: source.count, targetCount: target.count)
            ? levenshtein(source, target)
            : approximateDistance(source, target)
        let ratio = Double(distance) / Double(denominator)
        return min(1, max(0, ratio))
    }

    /// Trims and collapses whitespace runs so formatting-only differences don't
    /// inflate the magnitude.
    static func normalize(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }

    private static func canComputeExactDistance(sourceCount: Int, targetCount: Int) -> Bool {
        if sourceCount == 0 || targetCount == 0 { return true }
        return sourceCount <= exactDistanceCellLimit / targetCount
    }

    /// Linear fallback for long pasted edits: trim shared prefix and suffix, then
    /// treat the remaining span as a replace/insert/delete block.
    private static func approximateDistance(_ source: [Character], _ target: [Character]) -> Int {
        var prefixLength = 0
        while prefixLength < source.count,
              prefixLength < target.count,
              source[prefixLength] == target[prefixLength] {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < source.count - prefixLength,
              suffixLength < target.count - prefixLength,
              source[source.count - 1 - suffixLength] == target[target.count - 1 - suffixLength] {
            suffixLength += 1
        }

        let sourceRemainder = source.count - prefixLength - suffixLength
        let targetRemainder = target.count - prefixLength - suffixLength
        return max(sourceRemainder, targetRemainder)
    }

    /// Character-level Levenshtein distance with two-row dynamic programming.
    private static func levenshtein(_ source: [Character], _ target: [Character]) -> Int {
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        var previous = Array(0...target.count)
        var current = [Int](repeating: 0, count: target.count + 1)

        for row in 1...source.count {
            current[0] = row
            for col in 1...target.count {
                let substitutionCost = source[row - 1] == target[col - 1] ? 0 : 1
                current[col] = min(
                    previous[col] + 1,          // deletion
                    current[col - 1] + 1,       // insertion
                    previous[col - 1] + substitutionCost // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[target.count]
    }
}
