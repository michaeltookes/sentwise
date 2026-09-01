import Foundation

/// A pure, cheap measure of how much a user rewrote a draft before approving it
/// (item 83, Phase 1). It quantifies item 19's captured `originalBody` vs. the
/// final `body` as a single normalized number the feedback store can learn from.
///
/// **Metric (documented, fixed):** the normalized character-level edit-distance
/// ratio: exact Levenshtein for ordinary drafts, with bounded sparse-aware and
/// moved-block-aware fallbacks for unusually large pasted edits.
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
    private static let approximateResyncWindow = 64
    private static let boundedMovedBlockDistanceLimit = 2_048

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

    /// Linear fallback for long pasted edits. The resync window keeps sparse,
    /// separated edits from being counted as one large replacement span while
    /// the bounded alignment pass catches small moved blocks beyond the fixed
    /// lookahead without returning to an unbounded `O(n*m)` matrix.
    private static func approximateDistance(_ source: [Character], _ target: [Character]) -> Int {
        var distances = [
            positionalDistance(source, target),
            resyncingDistance(source, target),
            resyncingDistance(target, source)
        ]
        if let aligned = boundedMovedBlockDistance(source, target) {
            distances.append(aligned)
        }
        return distances.min() ?? max(source.count, target.count)
    }

    private static func positionalDistance(_ source: [Character], _ target: [Character]) -> Int {
        let sharedCount = min(source.count, target.count)
        let mismatches = (0..<sharedCount).reduce(0) { partial, index in
            partial + (source[index] == target[index] ? 0 : 1)
        }
        return mismatches + abs(source.count - target.count)
    }

    private static func resyncingDistance(_ source: [Character], _ target: [Character]) -> Int {
        var sourceIndex = 0
        var targetIndex = 0
        var distance = 0

        while sourceIndex < source.count, targetIndex < target.count {
            if source[sourceIndex] == target[targetIndex] {
                sourceIndex += 1
                targetIndex += 1
                continue
            }

            let sourceRemainder = source.count - sourceIndex
            let targetRemainder = target.count - targetIndex
            let insertionOffset = matchOffset(
                of: source[sourceIndex],
                in: target,
                after: targetIndex,
                maxOffset: approximateResyncWindow
            )
            let deletionOffset = matchOffset(
                of: target[targetIndex],
                in: source,
                after: sourceIndex,
                maxOffset: approximateResyncWindow
            )

            if targetRemainder > sourceRemainder, let insertionOffset {
                distance += insertionOffset
                targetIndex += insertionOffset
            } else if sourceRemainder > targetRemainder, let deletionOffset {
                distance += deletionOffset
                sourceIndex += deletionOffset
            } else if let insertionOffset, let deletionOffset {
                if insertionOffset <= deletionOffset {
                    distance += insertionOffset
                    targetIndex += insertionOffset
                } else {
                    distance += deletionOffset
                    sourceIndex += deletionOffset
                }
            } else if let insertionOffset {
                distance += insertionOffset
                targetIndex += insertionOffset
            } else if let deletionOffset {
                distance += deletionOffset
                sourceIndex += deletionOffset
            } else {
                distance += 1
                sourceIndex += 1
                targetIndex += 1
            }
        }

        return distance + (source.count - sourceIndex) + (target.count - targetIndex)
    }

    private static func matchOffset(
        of character: Character,
        in characters: [Character],
        after index: Int,
        maxOffset: Int
    ) -> Int? {
        guard maxOffset > 0 else { return nil }
        let start = index + 1
        guard start < characters.count else { return nil }
        let end = min(characters.count - 1, index + maxOffset)
        guard start <= end else { return nil }
        for candidate in start...end where characters[candidate] == character {
            return candidate - index
        }
        return nil
    }

    /// Myers-style insert/delete distance up to a fixed edit budget. This detects
    /// moved blocks beyond the small resync window, then bails out before it can
    /// become the quadratic post-send work the approximate path avoids.
    private static func boundedMovedBlockDistance(
        _ source: [Character],
        _ target: [Character]
    ) -> Int? {
        let maxDistance = boundedMovedBlockDistanceLimit
        guard abs(source.count - target.count) <= maxDistance else { return nil }

        let offset = maxDistance + 1
        var furthestSourceIndexByDiagonal = Array(repeating: -1, count: 2 * maxDistance + 3)
        furthestSourceIndexByDiagonal[offset + 1] = 0

        for distance in 0...maxDistance {
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                let index = offset + diagonal
                let shouldInsert = diagonal == -distance || (
                    diagonal != distance
                        && furthestSourceIndexByDiagonal[index - 1] < furthestSourceIndexByDiagonal[index + 1]
                )
                var sourceIndex = shouldInsert
                    ? furthestSourceIndexByDiagonal[index + 1]
                    : furthestSourceIndexByDiagonal[index - 1] + 1
                guard sourceIndex >= 0 else { continue }

                var targetIndex = sourceIndex - diagonal
                while sourceIndex < source.count,
                      targetIndex < target.count,
                      targetIndex >= 0,
                      source[sourceIndex] == target[targetIndex] {
                    sourceIndex += 1
                    targetIndex += 1
                }
                furthestSourceIndexByDiagonal[index] = sourceIndex

                if sourceIndex >= source.count, targetIndex >= target.count {
                    return distance
                }
            }
        }
        return nil
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
