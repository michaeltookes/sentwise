import Foundation

/// Decodes RFC 2047 "encoded-word" headers (e.g. `=?UTF-8?B?…?=`) for display.
///
/// Inbound IMAP subjects arrive with their non-ASCII parts encoded as
/// encoded-words. `OutgoingMessage.encodedSubject` produces them on the way out;
/// this is the missing inbound decoder for the way in. It is display-only and
/// never mutates stored values — callers decode a copy at render time.
///
/// Pure and deterministic. Handles both `B` (base64) and `Q` (quoted-printable)
/// encodings, UTF-8 / ISO-8859-1 (latin1) / US-ASCII / windows-1252 and any
/// other IANA charset Foundation recognises, multiple adjacent encoded-words
/// (per RFC 2047 the linear whitespace *between* two encoded-words is collapsed),
/// and mixed plain + encoded text. Anything malformed — a bad charset, invalid
/// base64, a truncated `=XX` escape — falls back to the raw substring rather than
/// crashing or dropping content.
enum MIMEEncodedWord {

    /// The encoded-word grammar: `=?charset?encoding?text?=`. Charset and text
    /// carry no whitespace or `?` (a literal `?` in Q-text is escaped as `=3F`),
    /// so the character classes below cannot run past the closing `?=`.
    private static let regex = try? NSRegularExpression(
        pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^\\s?]+)\\?="
    )

    /// Returns `input` with every well-formed encoded-word replaced by its
    /// decoded text. Input containing no encoded-words is returned unchanged.
    static func decode(_ input: String) -> String {
        guard input.contains("=?"), let regex else { return input }

        let ns = input as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: input, range: full)
        guard !matches.isEmpty else { return input }

        var result = ""
        var cursor = 0
        var previousWasEncoded = false

        for match in matches {
            let matchRange = match.range
            let gap = ns.substring(with: NSRange(
                location: cursor,
                length: matchRange.location - cursor
            ))

            let decoded = decodeWord(
                charset: ns.substring(with: match.range(at: 1)),
                encoding: ns.substring(with: match.range(at: 2)),
                text: ns.substring(with: match.range(at: 3))
            )

            if let decoded {
                // RFC 2047 §6.2: whitespace separating two adjacent encoded-words
                // is not part of the text and is collapsed away.
                let gapIsWhitespace = gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !(previousWasEncoded && gapIsWhitespace) {
                    result += gap
                }
                result += decoded
                previousWasEncoded = true
            } else {
                // Malformed word: keep the literal source so nothing is lost.
                result += gap
                result += ns.substring(with: matchRange)
                previousWasEncoded = false
            }

            cursor = matchRange.location + matchRange.length
        }

        result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        return result
    }

    /// Returns a subject suitable for UI labels: decoded when RFC 2047 encoded,
    /// with a readable fallback for empty subjects.
    static func displaySubject(_ subject: String) -> String {
        subject.isEmpty ? "(no subject)" : decode(subject)
    }

    // MARK: - One encoded-word

    /// Decodes a single encoded-word's payload, or `nil` when the charset is
    /// unknown or the payload cannot be decoded (caller falls back to raw text).
    private static func decodeWord(charset: String, encoding: String, text: String) -> String? {
        guard !text.isEmpty else { return nil }

        let bytes: [UInt8]?
        switch encoding.uppercased() {
        case "B":
            bytes = Data(base64Encoded: text).map { [UInt8]($0) }
        case "Q":
            bytes = decodeQ(text)
        default:
            return nil
        }
        guard let bytes, let stringEncoding = stringEncoding(for: charset) else { return nil }
        return String(bytes: bytes, encoding: stringEncoding)
    }

    /// Decodes RFC 2047 "Q" encoding: `_` is a space and `=XX` is a hex byte;
    /// everything else is literal. Returns `nil` on a truncated/invalid escape.
    private static func decodeQ(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case UInt8(ascii: "_"):
                bytes.append(UInt8(ascii: " "))
                index += 1
            case UInt8(ascii: "="):
                guard index + 2 < chars.count,
                      let high = hexValue(chars[index + 1]),
                      let low = hexValue(chars[index + 2]) else { return nil }
                bytes.append((high << 4) | low)
                index += 3
            default:
                bytes.append(char)
                index += 1
            }
        }
        return bytes
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    /// Maps a charset label to a `String.Encoding`. The common cases are spelled
    /// out; anything else defers to Foundation's IANA charset table.
    private static func stringEncoding(for charset: String) -> String.Encoding? {
        let baseCharset = charset.split(separator: "*", maxSplits: 1).first.map(String.init) ?? charset
        switch baseCharset.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "us-ascii", "ascii":
            return .ascii
        case "iso-8859-1", "iso8859-1", "8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(baseCharset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
    }
}
