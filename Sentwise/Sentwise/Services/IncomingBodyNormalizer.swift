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

    /// Strips paired emphasis markers (`**`, `__`, backticks). Bare single `*`/`_`
    /// are left alone to avoid mangling prose that legitimately uses them.
    private static func stripEmphasis(_ line: String) -> String {
        var result = line
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        return result
    }

    /// Converts `[label](url)` to just `label`, dropping the (often tracking-laden)
    /// URL. Uses a regex; on failure returns the input unchanged.
    private static func simplifyLinks(_ line: String) -> String {
        guard line.contains("]("), let regex = linkRegex else { return line }
        let ns = line as NSString
        return regex.stringByReplacingMatches(
            in: line,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "$1"
        )
    }

    private static let linkRegex = try? NSRegularExpression(
        pattern: "\\[([^\\]]*)\\]\\([^)]*\\)"
    )

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
