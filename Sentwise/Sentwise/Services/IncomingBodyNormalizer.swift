import Foundation

/// Cleans plain-text incoming-message bodies for readable display.
enum IncomingBodyNormalizer {

    /// Returns a cleaned copy of `input` suitable for display.
    static func normalize(_ input: String) -> String {
        guard !input.isEmpty else { return input }

        var text = normalizeWhitespaceCharacters(input)
        var fenceState: FenceState?
        var indentedCodeDepth: Int?
        var inlineCodeState: InlineCodeState?
        let rawLines = text.components(separatedBy: "\n")
        let lines = rawLines.indices.map { index in
            let nextIndex = rawLines.index(after: index)
            return cleanLine(
                rawLines[index],
                fenceState: &fenceState,
                indentedCodeDepth: &indentedCodeDepth,
                inlineCodeState: &inlineCodeState,
                followingLines: rawLines[nextIndex...]
            )
        }
        let collapsedLines = trimDisplayEdges(collapseBlankRuns(lines))
        text = collapsedLines.map(\.text).joined(separator: "\n")
        return text
    }

    /// Unifies line endings and neutralises invisible/odd whitespace that
    /// HTML-derived text carries (CRLF, NBSP, zero-width space, BOM).
    private static func normalizeWhitespaceCharacters(_ input: String) -> String {
        var text = input
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space
        text = text.replacingOccurrences(of: "\u{200B}", with: "")    // zero-width space
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")    // BOM / zero-width no-break
        return text
    }

    /// Cleans one line: drops horizontal rules, strips heading/quote/emphasis
    /// markers, simplifies links, and collapses interior space runs. A line that
    /// was only a rule becomes empty (folded away by `collapseBlankRuns`).
    private static func cleanLine(
        _ rawLine: String,
        fenceState: inout FenceState?,
        indentedCodeDepth: inout Int?,
        inlineCodeState: inout InlineCodeState?,
        followingLines: ArraySlice<String>
    ) -> CleanedLine {
        let trimmedTrailing = String(rawLine.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        let unquotedRaw = stripBlockquoteMarkers(rawLine).text

        if inlineCodeState != nil {
            return cleanInlineMarkdown(
                unquotedRaw,
                inlineCodeState: &inlineCodeState,
                followingLines: followingLines
            )
        }

        if let fence = fenceState {
            let strippedTrailing = stripBlockquoteMarkers(trimmedTrailing, maxDepth: fence.blockquoteDepth)
            let fenceLine = fence.stripsBlockquote && strippedTrailing.depth == fence.blockquoteDepth
                ? strippedTrailing.text
                : trimmedTrailing
            if let candidate = fenceCandidate(fenceLine), fence.closes(candidate) {
                fenceState = nil
                return CleanedLine("")
            }
            let strippedRaw = stripBlockquoteMarkers(rawLine, maxDepth: fence.blockquoteDepth)
            let literalLine = fence.stripsBlockquote && strippedRaw.depth == fence.blockquoteDepth
                ? strippedRaw.text
                : rawLine
            return CleanedLine(literalLine, preservesBlankRuns: true)
        }

        if let depth = indentedCodeDepth {
            let stripped = stripBlockquoteMarkers(rawLine, maxDepth: depth)
            if stripped.text.trimmingCharacters(in: .whitespaces).isEmpty {
                return CleanedLine(stripped.text, preservesBlankRuns: true)
            } else if let literalLine = indentedCodeLine(rawLine, maxBlockquoteDepth: depth) {
                indentedCodeDepth = literalLine.blockquoteDepth
                return CleanedLine(literalLine.text, preservesBlankRuns: true)
            }
            indentedCodeDepth = nil
        }

        if let candidate = fenceCandidate(trimmedTrailing),
           let fence = FenceState(openingLine: candidate, blockquoteDepth: 0) {
            fenceState = fence
            return CleanedLine("")
        }

        let strippedOpening = stripBlockquoteMarkers(trimmedTrailing)
        let unquotedTrimmed = strippedOpening.text.trimmingCharacters(in: .whitespaces)
        if strippedOpening.depth > 0,
           let candidate = fenceCandidate(strippedOpening.text),
           let fence = FenceState(openingLine: candidate, blockquoteDepth: strippedOpening.depth) {
            fenceState = fence
            return CleanedLine("")
        }

        if let literalLine = indentedCodeLine(rawLine) {
            indentedCodeDepth = literalLine.blockquoteDepth
            return CleanedLine(literalLine.text, preservesBlankRuns: true)
        }

        if isHorizontalRule(unquotedTrimmed) { return CleanedLine("") }

        var line = unquotedRaw
        line = stripHeadingMarker(line)
        line = normalizeListMarker(line)
        return cleanInlineMarkdown(
            line,
            inlineCodeState: &inlineCodeState,
            followingLines: followingLines
        )
    }

    struct CleanedLine {
        let text: String
        let preservesBlankRuns: Bool

        init(_ text: String, preservesBlankRuns: Bool = false) {
            self.text = text
            self.preservesBlankRuns = preservesBlankRuns
        }
    }

    struct InlineCodeState {
        let delimiterLength: Int
    }

    private struct FenceState {
        let delimiter: Character
        let length: Int
        let blockquoteDepth: Int
        var stripsBlockquote: Bool { blockquoteDepth > 0 }

        init?(openingLine: String, blockquoteDepth: Int) {
            guard let first = openingLine.first, first == "`" || first == "~" else { return nil }
            let count = openingLine.prefix { $0 == first }.count
            guard count >= 3 else { return nil }
            let infoStart = openingLine.index(openingLine.startIndex, offsetBy: count)
            let info = openingLine[infoStart...]
            guard first != "`" || !info.contains("`") else {
                return nil
            }
            delimiter = first
            length = count
            self.blockquoteDepth = blockquoteDepth
        }

        func closes(_ line: String) -> Bool {
            let count = line.prefix { $0 == delimiter }.count
            guard count >= length else { return false }
            let restStart = line.index(line.startIndex, offsetBy: count)
            return line[restStart...].allSatisfy { $0 == " " || $0 == "\t" }
        }
    }

    private static func fenceCandidate(_ line: String) -> String? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else { return nil }
        return String(line.dropFirst(leadingSpaces))
    }

    private static func indentedCodeLine(
        _ rawLine: String,
        maxBlockquoteDepth: Int? = nil
    ) -> (text: String, blockquoteDepth: Int)? {
        let stripped = stripBlockquoteMarkers(rawLine, maxDepth: maxBlockquoteDepth)
        guard hasIndentedCodePrefix(stripped.text),
              !stripped.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (stripped.text, stripped.depth)
    }

    private static func hasIndentedCodePrefix(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    /// A markdown/stripped-HTML horizontal rule: three or more of `-`, `*`, `_`,
    /// or `=`, optionally spaced, with nothing else on the line.
    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        let ruleCharacters: Set<Character> = ["-", "*", "_", "="]
        return stripped.allSatisfy { ruleCharacters.contains($0) }
    }

    /// Removes a leading ATX heading marker (`#`, `##`, …) and its space.
    private static func stripHeadingMarker(_ line: String) -> String {
        var index = line.startIndex
        var hashes = 0
        while index < line.endIndex, line[index] == "#", hashes < 6 {
            index = line.index(after: index)
            hashes += 1
        }
        guard hashes > 0, index < line.endIndex, line[index] == " " else { return line }
        return String(line[line.index(after: index)...])
    }

    private struct BlockquoteStripped { let text: String; let depth: Int }

    /// Removes leading blockquote markers (`> `), including nested `> > `.
    private static func stripBlockquoteMarkers(_ line: String, maxDepth: Int? = nil) -> BlockquoteStripped {
        var result = line
        var depth = 0
        while result.hasPrefix(">"), maxDepth.map({ depth < $0 }) ?? true {
            result.removeFirst()
            if result.hasPrefix(" ") { result.removeFirst() }
            depth += 1
        }
        return BlockquoteStripped(text: result, depth: depth)
    }

    /// Normalises an unordered-list marker (`* `, `- `, `+ `) to a bullet, so
    /// asterisks used as bullets don't get confused with emphasis.
    private static func normalizeListMarker(_ line: String) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line[line.index(line.startIndex, offsetBy: leading.count)...]
        for marker in ["* ", "- ", "+ "] where rest.hasPrefix(marker) {
            return leading + "• " + rest.dropFirst(marker.count)
        }
        return line
    }
}

fileprivate extension IncomingBodyNormalizer {
    /// Collapses runs of blank lines so at most one blank line separates
    /// paragraphs, and drops leading blank lines.
    private static func collapseBlankRuns(_ lines: [CleanedLine]) -> [CleanedLine] {
        var result: [CleanedLine] = []
        var pendingBlank = false
        for line in lines {
            if line.preservesBlankRuns {
                if pendingBlank && !result.isEmpty && result.last?.text.trimmingCharacters(in: .whitespaces).isEmpty == false {
                    result.append(CleanedLine(""))
                }
                pendingBlank = false
                result.append(line)
                continue
            }

            if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingBlank = true
                continue
            }
            if pendingBlank && !result.isEmpty && result.last?.text.trimmingCharacters(in: .whitespaces).isEmpty == false {
                result.append(CleanedLine(""))
            }
            pendingBlank = false
            result.append(line)
        }
        return result
    }

    private static func trimDisplayEdges(_ lines: [CleanedLine]) -> [CleanedLine] {
        guard !lines.isEmpty else { return [] }

        var result = lines
        if let first = result.first, !first.preservesBlankRuns {
            let text = result.count == 1
                ? trimTrailingWhitespace(trimLeadingWhitespace(first.text))
                : trimLeadingWhitespace(first.text)
            result[0] = CleanedLine(text)
        }
        if result.count > 1, let last = result.last, !last.preservesBlankRuns {
            result[result.count - 1] = CleanedLine(trimTrailingWhitespace(last.text))
        }
        return result
    }

    private static func trimLeadingWhitespace(_ text: String) -> String {
        String(text.drop { $0 == " " || $0 == "\t" })
    }

    private static func trimTrailingWhitespace(_ text: String) -> String {
        String(text.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
}
