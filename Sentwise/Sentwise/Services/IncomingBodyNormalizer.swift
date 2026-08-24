import Foundation

/// Cleans the plain-text incoming-message body for readable display (item 69).
///
/// The stored `Draft.incomingBody` is the raw text extracted from the source
/// message: GitHub and marketing mail leave literal markdown (`###`, `**`,
/// `[text](url)`) and HTML-to-text artifacts (rules made of `---`/`===`, runs of
/// blank lines, zero-width-space and non-breaking-space artifacts). Rendered verbatim in a
/// `Text` view that reads as noise. This normaliser strips the noisiest markers
/// and collapses the whitespace so the message is legible at a glance — it is a
/// lightweight cleanup, not an HTML/markdown engine.
///
/// Pure, deterministic, and value-safe: it never mutates the stored draft
/// (callers normalise a copy at render time) and always returns a string.
enum IncomingBodyNormalizer {

    /// Returns a cleaned copy of `input` suitable for display.
    static func normalize(_ input: String) -> String {
        guard !input.isEmpty else { return input }

        var text = normalizeWhitespaceCharacters(input)
        var fenceState: FenceState?
        let lines = text.components(separatedBy: "\n").map {
            cleanLine($0, fenceState: &fenceState)
        }
        let collapsedLines = trimDisplayEdges(collapseBlankRuns(lines))
        text = collapsedLines.map(\.text).joined(separator: "\n")
        return text
    }

    // MARK: - Steps

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
    private static func cleanLine(_ rawLine: String, fenceState: inout FenceState?) -> CleanedLine {
        let trimmedTrailing = String(rawLine.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        let unquotedRaw = stripBlockquoteMarker(rawLine)
        let unquotedTrimmedTrailing = stripBlockquoteMarker(trimmedTrailing)

        if let fence = fenceState {
            let fenceLine = fence.stripsBlockquote ? unquotedTrimmedTrailing : trimmedTrailing
            let trimmed = fenceLine.trimmingCharacters(in: .whitespaces)
            if fence.closes(trimmed) {
                fenceState = nil
                return CleanedLine("")
            }
            let literalLine = fence.stripsBlockquote ? unquotedRaw : rawLine
            return CleanedLine(literalLine, preservesBlankRuns: true)
        }

        let trimmed = trimmedTrailing.trimmingCharacters(in: .whitespaces)
        if let fence = FenceState(openingLine: trimmed, stripsBlockquote: false) {
            fenceState = fence
            return CleanedLine("")
        }

        let unquotedTrimmed = unquotedTrimmedTrailing.trimmingCharacters(in: .whitespaces)
        if unquotedTrimmedTrailing != trimmedTrailing,
           let fence = FenceState(openingLine: unquotedTrimmed, stripsBlockquote: true) {
            fenceState = fence
            return CleanedLine("")
        }

        if isHorizontalRule(unquotedTrimmed) { return CleanedLine("") }

        var line = unquotedTrimmedTrailing
        line = stripHeadingMarker(line)
        line = normalizeListMarker(line)
        line = cleanInlineMarkdown(line)
        return CleanedLine(line)
    }

    private struct CleanedLine {
        let text: String
        let preservesBlankRuns: Bool

        init(_ text: String, preservesBlankRuns: Bool = false) {
            self.text = text
            self.preservesBlankRuns = preservesBlankRuns
        }
    }

    private struct FenceState {
        let delimiter: Character
        let length: Int
        let stripsBlockquote: Bool

        init?(openingLine: String, stripsBlockquote: Bool) {
            guard let first = openingLine.first, first == "`" || first == "~" else { return nil }
            let count = openingLine.prefix { $0 == first }.count
            guard count >= 3 else { return nil }
            let infoStart = openingLine.index(openingLine.startIndex, offsetBy: count)
            let info = openingLine[infoStart...]
            guard first != "`" || !Self.containsDelimiterRun(in: info, delimiter: first, minimumLength: count) else {
                return nil
            }
            delimiter = first
            length = count
            self.stripsBlockquote = stripsBlockquote
        }

        func closes(_ line: String) -> Bool {
            let count = line.prefix { $0 == delimiter }.count
            guard count >= length else { return false }
            let restStart = line.index(line.startIndex, offsetBy: count)
            return line[restStart...].allSatisfy { $0 == " " || $0 == "\t" }
        }

        private static func containsDelimiterRun(
            in text: Substring,
            delimiter: Character,
            minimumLength: Int
        ) -> Bool {
            var runLength = 0
            for character in text {
                if character == delimiter {
                    runLength += 1
                    if runLength >= minimumLength { return true }
                } else {
                    runLength = 0
                }
            }
            return false
        }
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

    /// Removes a leading blockquote marker (`> `), including nested `> > `.
    private static func stripBlockquoteMarker(_ line: String) -> String {
        var result = line
        while result.hasPrefix(">") {
            result.removeFirst()
            if result.hasPrefix(" ") { result.removeFirst() }
        }
        return result
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

    /// Cleans prose Markdown while preserving code-span contents literally.
    private static func cleanInlineMarkdown(_ line: String) -> String {
        var result = ""
        var proseSegment = ""
        var index = line.startIndex

        while index < line.endIndex {
            guard line[index] == "`" else {
                proseSegment.append(line[index])
                index = line.index(after: index)
                continue
            }

            let codeStart = backtickRunEnd(in: line, startingAt: index)
            let delimiterLength = line.distance(from: index, to: codeStart)
            guard let codeEnd = closingBacktickRun(
                in: line,
                delimiterLength: delimiterLength,
                after: codeStart
            ) else {
                // Preserve the old cleanup behavior for stray backtick runs.
                index = codeStart
                continue
            }

            result += cleanInlineProse(proseSegment)
            proseSegment.removeAll(keepingCapacity: true)
            result.append(contentsOf: line[codeStart..<codeEnd])
            index = line.index(codeEnd, offsetBy: delimiterLength)
        }

        result += cleanInlineProse(proseSegment)
        return result
    }

    private static func backtickRunEnd(in line: String, startingAt index: String.Index) -> String.Index {
        var runEnd = index
        while runEnd < line.endIndex, line[runEnd] == "`" {
            runEnd = line.index(after: runEnd)
        }
        return runEnd
    }

    private static func closingBacktickRun(
        in line: String,
        delimiterLength: Int,
        after index: String.Index
    ) -> String.Index? {
        var current = index
        while current < line.endIndex {
            guard line[current] == "`" else {
                current = line.index(after: current)
                continue
            }

            let runEnd = backtickRunEnd(in: line, startingAt: current)
            if line.distance(from: current, to: runEnd) == delimiterLength {
                return current
            }
            current = runEnd
        }
        return nil
    }

    private static func stripProseEmphasis(_ line: String) -> String {
        stripDelimitedEmphasis(
            stripDelimitedEmphasis(line, delimiter: "**"),
            delimiter: "__"
        )
    }

    private static func cleanInlineProse(_ line: String) -> String {
        collapseSpaces(simplifyLinks(stripProseEmphasis(line)))
    }

    private static func stripDelimitedEmphasis(_ line: String, delimiter: String) -> String {
        guard line.contains(delimiter) else { return line }

        var openers: [Range<String.Index>] = []
        var removals: [Range<String.Index>] = []
        var index = line.startIndex
        while index < line.endIndex {
            if line[index...].hasPrefix(delimiter) {
                let range = index..<line.index(index, offsetBy: delimiter.count)
                if isEscaped(in: line, at: index) {
                    index = range.upperBound
                    continue
                }
                let canOpen = canOpenEmphasis(in: line, at: index, delimiter: delimiter)
                let canClose = canCloseEmphasis(in: line, at: index, delimiter: delimiter)
                if canClose, let opener = openers.popLast() {
                    removals.append(opener)
                    removals.append(range)
                } else if canOpen {
                    openers.append(range)
                }
                index = range.upperBound
            } else {
                index = line.index(after: index)
            }
        }

        guard !removals.isEmpty else { return line }

        var result = ""
        index = line.startIndex
        for removal in removals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            result.append(contentsOf: line[index..<removal.lowerBound])
            index = removal.upperBound
        }
        result.append(contentsOf: line[index...])
        return result
    }

    private static func isEscaped(in line: String, at index: String.Index) -> Bool {
        var slashCount = 0
        var current = index
        while current > line.startIndex {
            let previous = line.index(before: current)
            guard line[previous] == "\\" else { break }
            slashCount += 1
            current = previous
        }
        return !slashCount.isMultiple(of: 2)
    }

    private static func canOpenEmphasis(in line: String, at index: String.Index, delimiter: String) -> Bool {
        let contentStart = line.index(index, offsetBy: delimiter.count)
        guard contentStart < line.endIndex, !line[contentStart].isWhitespace else { return false }
        guard index > line.startIndex else { return true }
        return !isIdentifierCharacter(line[line.index(before: index)])
    }

    private static func canCloseEmphasis(in line: String, at index: String.Index, delimiter: String) -> Bool {
        guard index > line.startIndex, !line[line.index(before: index)].isWhitespace else { return false }
        let delimiterEnd = line.index(index, offsetBy: delimiter.count)
        guard delimiterEnd < line.endIndex else { return true }
        return !isIdentifierCharacter(line[delimiterEnd])
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Converts `[label](url)` to just `label`, dropping the (often tracking-laden)
    /// URL. Link destinations can contain escaped or balanced parentheses.
    private static func simplifyLinks(_ line: String) -> String {
        guard line.contains("](") else { return line }

        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "[", !isEscaped(in: line, at: index),
               let labelEnd = closingLabelBracket(in: line, after: line.index(after: index)) {
                let destinationStart = line.index(after: labelEnd)
                if destinationStart < line.endIndex, line[destinationStart] == "(" {
                    let urlStart = line.index(after: destinationStart)
                    if let destinationEnd = closingDestinationParen(in: line, after: urlStart) {
                        result.append(contentsOf: line[line.index(after: index)..<labelEnd])
                        index = line.index(after: destinationEnd)
                        continue
                    }
                    result.append(contentsOf: line[index...])
                    break
                }
                result.append(contentsOf: line[index...labelEnd])
                index = line.index(after: labelEnd)
                continue
            } else if line[index] == "[" {
                guard closingLabelBracket(in: line, after: line.index(after: index)) != nil else {
                    result.append(contentsOf: line[index...])
                    break
                }
            }

            result.append(line[index])
            index = line.index(after: index)
        }

        return result
    }

    private static func closingLabelBracket(in line: String, after index: String.Index) -> String.Index? {
        var current = index
        while current < line.endIndex {
            if line[current] == "\\" {
                current = line.index(after: current)
                if current < line.endIndex { current = line.index(after: current) }
                continue
            }
            if line[current] == "]" { return current }
            current = line.index(after: current)
        }
        return nil
    }

    private static func closingDestinationParen(in line: String, after index: String.Index) -> String.Index? {
        var depth = 0
        var current = index
        while current < line.endIndex {
            if line[current] == "\\" {
                current = line.index(after: current)
                if current < line.endIndex { current = line.index(after: current) }
                continue
            }
            if line[current] == "(" {
                depth += 1
            } else if line[current] == ")" {
                guard depth > 0 else { return current }
                depth -= 1
            }
            current = line.index(after: current)
        }
        return nil
    }

    /// Collapses runs of two or more interior spaces/tabs into a single space.
    private static func collapseSpaces(_ line: String) -> String {
        guard line.contains("  ") || line.contains("\t") else { return line }
        var result = ""
        var lastWasSpace = false
        for char in line {
            if char == " " || char == "\t" {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(char)
                lastWasSpace = false
            }
        }
        return result
    }

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
