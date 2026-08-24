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
        let lines = text.components(separatedBy: "\n").map(cleanLine)
        text = collapseBlankRuns(lines).joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private static func cleanLine(_ rawLine: String) -> String {
        let trimmedTrailing = String(rawLine.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        let trimmed = trimmedTrailing.trimmingCharacters(in: .whitespaces)

        if isHorizontalRule(trimmed) { return "" }

        var line = trimmedTrailing
        line = stripHeadingMarker(line)
        line = stripBlockquoteMarker(line)
        line = normalizeListMarker(line)
        line = stripEmphasis(line)
        line = simplifyLinks(line)
        line = collapseSpaces(line)
        return line
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

    /// Strips paired emphasis markers (`**`, `__`, backtick code spans). Bare or
    /// intraword `*`/`_` markers are left alone to avoid mangling identifiers.
    private static func stripEmphasis(_ line: String) -> String {
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

            result += stripProseEmphasis(proseSegment)
            proseSegment.removeAll(keepingCapacity: true)
            result.append(contentsOf: line[codeStart..<codeEnd])
            index = line.index(codeEnd, offsetBy: delimiterLength)
        }

        result += stripProseEmphasis(proseSegment)
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

    private static func stripDelimitedEmphasis(_ line: String, delimiter: String) -> String {
        guard line.contains(delimiter) else { return line }

        var openers: [Range<String.Index>] = []
        var removals: [Range<String.Index>] = []
        var index = line.startIndex
        while index < line.endIndex {
            if line[index...].hasPrefix(delimiter) {
                let range = index..<line.index(index, offsetBy: delimiter.count)
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
            if line[index] == "[",
               let labelEnd = closingLabelBracket(in: line, after: line.index(after: index)) {
                let destinationStart = line.index(after: labelEnd)
                if destinationStart < line.endIndex, line[destinationStart] == "(" {
                    let urlStart = line.index(after: destinationStart)
                    if let destinationEnd = closingDestinationParen(in: line, after: urlStart) {
                        result.append(contentsOf: line[line.index(after: index)..<labelEnd])
                        index = line.index(after: destinationEnd)
                        continue
                    }
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
    private static func collapseBlankRuns(_ lines: [String]) -> [String] {
        var result: [String] = []
        var pendingBlank = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingBlank = true
                continue
            }
            if pendingBlank && !result.isEmpty {
                result.append("")
            }
            pendingBlank = false
            result.append(line)
        }
        return result
    }
}
