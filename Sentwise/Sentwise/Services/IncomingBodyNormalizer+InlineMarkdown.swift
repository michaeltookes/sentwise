import Foundation

extension IncomingBodyNormalizer {
    static func cleanInlineMarkdown(
        _ line: String,
        inlineCodeState: inout InlineCodeState?,
        followingLines: ArraySlice<String>
    ) -> CleanedLine {
        var result = ""
        var proseSegment = ""
        var index = line.startIndex
        let preservesBlankRuns = inlineCodeState != nil

        while index < line.endIndex {
            if let state = inlineCodeState {
                guard let codeEnd = closingBacktickRun(
                    in: line,
                    delimiterLength: state.delimiterLength,
                    after: index
                ) else {
                    result.append(contentsOf: line[index...])
                    return CleanedLine(result, preservesBlankRuns: true)
                }
                result.append(contentsOf: line[index..<codeEnd])
                index = line.index(codeEnd, offsetBy: state.delimiterLength)
                inlineCodeState = nil
                continue
            }

            guard line[index] == "`" else {
                proseSegment.append(line[index])
                index = line.index(after: index)
                continue
            }
            if isEscaped(in: line, at: index) {
                proseSegment.append(line[index])
                index = line.index(after: index)
                continue
            }

            let codeStart = backtickRunEnd(in: line, startingAt: index)
            let delimiterLength = line.distance(from: index, to: codeStart)
            if let codeEnd = closingBacktickRun(
                in: line,
                delimiterLength: delimiterLength,
                after: codeStart
            ) {
                result += cleanInlineProse(proseSegment)
                proseSegment.removeAll(keepingCapacity: true)
                result.append(contentsOf: line[codeStart..<codeEnd])
                index = line.index(codeEnd, offsetBy: delimiterLength)
                continue
            }

            guard hasClosingBacktickRun(delimiterLength: delimiterLength, in: followingLines) else {
                proseSegment.append(contentsOf: line[index..<codeStart])
                index = codeStart
                continue
            }
            result += cleanInlineProse(proseSegment)
            proseSegment.removeAll(keepingCapacity: true)
            result.append(contentsOf: line[codeStart...])
            inlineCodeState = InlineCodeState(delimiterLength: delimiterLength)
            return CleanedLine(result, preservesBlankRuns: true)
        }

        result += cleanInlineProse(trimTrailingProseWhitespace(proseSegment))
        return CleanedLine(result, preservesBlankRuns: preservesBlankRuns)
    }
}

private extension IncomingBodyNormalizer {
    static func hasClosingBacktickRun(
        delimiterLength: Int,
        in followingLines: ArraySlice<String>
    ) -> Bool {
        followingLines.contains {
            closingBacktickRun(in: $0, delimiterLength: delimiterLength, after: $0.startIndex) != nil
        }
    }

    static func backtickRunEnd(in line: String, startingAt index: String.Index) -> String.Index {
        var runEnd = index
        while runEnd < line.endIndex, line[runEnd] == "`" {
            runEnd = line.index(after: runEnd)
        }
        return runEnd
    }

    static func closingBacktickRun(
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
            if isEscaped(in: line, at: current) {
                current = runEnd
                continue
            }
            if line.distance(from: current, to: runEnd) == delimiterLength {
                return current
            }
            current = runEnd
        }
        return nil
    }

    static func stripProseEmphasis(_ line: String) -> String {
        stripDelimitedEmphasis(
            stripDelimitedEmphasis(line, delimiter: "**"),
            delimiter: "__"
        )
    }

    static func cleanInlineProse(_ line: String) -> String {
        collapseSpaces(simplifyLinks(stripProseEmphasis(line)))
    }

    static func trimTrailingProseWhitespace(_ text: String) -> String {
        String(text.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }

    static func stripDelimitedEmphasis(_ line: String, delimiter: String) -> String {
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

    static func isEscaped(in line: String, at index: String.Index) -> Bool {
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

    static func canOpenEmphasis(in line: String, at index: String.Index, delimiter: String) -> Bool {
        let contentStart = line.index(index, offsetBy: delimiter.count)
        guard contentStart < line.endIndex, !line[contentStart].isWhitespace else { return false }
        guard index > line.startIndex else { return true }
        return !isIdentifierCharacter(line[line.index(before: index)])
    }

    static func canCloseEmphasis(in line: String, at index: String.Index, delimiter: String) -> Bool {
        guard index > line.startIndex, !line[line.index(before: index)].isWhitespace else { return false }
        let delimiterEnd = line.index(index, offsetBy: delimiter.count)
        guard delimiterEnd < line.endIndex else { return true }
        return !isIdentifierCharacter(line[delimiterEnd])
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    static func simplifyLinks(_ line: String) -> String {
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

    static func closingLabelBracket(in line: String, after index: String.Index) -> String.Index? {
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

    static func closingDestinationParen(in line: String, after index: String.Index) -> String.Index? {
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

    static func collapseSpaces(_ line: String) -> String {
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
}
