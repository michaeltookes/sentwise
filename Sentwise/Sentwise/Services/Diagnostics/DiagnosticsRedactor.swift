import Foundation

/// Scrubs personally-identifiable and secret material out of a diagnostics
/// bundle before it ever leaves the app (item 36).
///
/// The bundle must be **default-safe**: assume a stranger will paste it into a
/// public issue or forum. The app is already designed never to log message
/// bodies, subjects, or recipient content, so this is the belt-and-suspenders
/// safety net — the whole assembled report (context header included) is run
/// through `redact(_:)` so an accidentally-logged address or token is still
/// removed.
///
/// Redaction is intentionally conservative and easy to reason about:
/// - **Email addresses** → `[redacted-email]` (the primary PII risk in a log).
/// - **Bearer tokens / `Authorization:` values** → `[redacted-token]` (managed
///   session JWTs and API keys, should any ever reach a log line).
/// - **Absolute filesystem paths** → `[redacted-path]` (macOS usernames and
///   transcript filenames can appear in private unified-log interpolations).
///
/// It is a pure function of its input so it can be unit-tested exhaustively
/// without touching the log store or the filesystem.
enum DiagnosticsRedactor {

    /// Replacement for a redacted email address.
    static let emailPlaceholder = "[redacted-email]"

    /// Replacement for a redacted bearer/authorization token or API key.
    static let tokenPlaceholder = "[redacted-token]"

    /// Replacement for a redacted absolute filesystem path.
    static let pathPlaceholder = "[redacted-path]"

    /// Matches an email address, including internal domains without a public TLD.
    private static let emailPattern =
        #"\b[A-Z0-9._%+\-]+@[A-Z0-9][A-Z0-9._\-]*\b"#

    /// Matches `Bearer <token>` (keeps the `Bearer` label, drops the value).
    private static let bearerPattern =
        #"(?i)(bearer)\s+[A-Za-z0-9._\-]{6,}"#

    /// Lowercased key fragments that make a key/value field secret-looking.
    private static let secretKeyNeedles = [
        "authorization",
        "apikey",
        "password",
        "passwd",
        "privatekey",
        "secret",
        "sessionid",
        "token"
    ]

    /// Matches a quoted secret value, including escaped JSON-style quotes.
    private static let quotedSecretValuePattern =
        #"\\?["'][^\r\n]*?\\?["']"#

    /// Matches an unquoted secret value until punctuation or the next compact
    /// key/value field. This lets `password: correct horse` redact the whole
    /// value without swallowing `sessionId=...` when another field follows.
    private static let unquotedSecretValuePattern =
        #".+?(?=$|[\r\n"'`,;)}]|\s+[A-Za-z][A-Za-z0-9_-]*\s*[:=])"#

    /// Matches a `key: value` / `key=value` pair whose key names a secret, so an
    /// inline `token=...`, `apiKey=...`, `password=...`, or `authorization: ...`
    /// value is scrubbed even when the key/value is JSON-quoted or the value
    /// itself doesn't look like an email or bearer.
    private static let secretAssignmentPattern =
        #"((?:\\?["'])?\b([A-Z0-9][A-Z0-9_-]*)(?:\\?["'])?\s*[:=]\s*)("#
        + quotedSecretValuePattern
        + #"|"#
        + unquotedSecretValuePattern
        + #")"#

    private static let secretAssignmentRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: secretAssignmentPattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Invalid diagnostics secret assignment regex: \(error)")
        }
    }()

    /// Matches quoted absolute paths, preserving the opening quote.
    private static let quotedPathPattern =
        #"(?m)(["'`])/(?!/)([^"'`\r\n]*)"#

    /// Matches filesystem URLs emitted by Foundation/logging, such as
    /// `file:///Users/name/Client%20Calls/call.vtt`.
    private static let fileURLPattern =
        #"(?i)\bfile:///[^\s"'`,;)]+"#

    /// Matches an unquoted absolute path body until punctuation that usually
    /// separates log fields. This intentionally consumes spaces for local paths
    /// like `/Volumes/Client Calls/customer interview.vtt`.
    private static let unquotedPathTailPattern =
        #"(.+?)(?=$|[\r\n"'`,;)]|\s+[A-Za-z][A-Za-z0-9_-]*\s*[:=])"#

    /// Matches log phrases ending with `: /absolute/path`, including filenames
    /// with spaces through the end of that log line.
    private static let colonPathPattern =
        #"(?m)(:\s+)/(?!/)([^\r\n]*)"#

    /// Matches compact `path=/absolute/path` / `file: /absolute/path` fields.
    private static let labeledPathPattern =
        #"(?im)\b(path|file|folder|directory|seenKey|key)(\s*[:=]\s*)/"#
        + #"(?!/)"#
        + unquotedPathTailPattern

    /// Matches unquoted absolute paths in free-form errors, stopping before the
    /// next separator so space-containing path components are fully scrubbed.
    private static let barePathPattern =
        #"(?m)(^|[\s(])/(?!/)"#
        + unquotedPathTailPattern

    /// Returns `text` with email addresses and secret-looking tokens redacted.
    static func redact(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: emailPattern,
            with: emailPlaceholder,
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: bearerPattern,
            with: "Bearer \(tokenPlaceholder)",
            options: [.regularExpression]
        )
        result = redactSecretAssignments(in: result)
        result = result.replacingOccurrences(
            of: fileURLPattern,
            with: "file://\(pathPlaceholder)",
            options: [.regularExpression]
        )
        result = result.replacingOccurrences(
            of: quotedPathPattern,
            with: "$1\(pathPlaceholder)",
            options: [.regularExpression]
        )
        result = result.replacingOccurrences(
            of: labeledPathPattern,
            with: "$1$2\(pathPlaceholder)",
            options: [.regularExpression]
        )
        result = result.replacingOccurrences(
            of: colonPathPattern,
            with: "$1\(pathPlaceholder)",
            options: [.regularExpression]
        )
        result = result.replacingOccurrences(
            of: barePathPattern,
            with: "$1\(pathPlaceholder)",
            options: [.regularExpression]
        )
        return result
    }

    private static func redactSecretAssignments(in text: String) -> String {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = secretAssignmentRegex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        let original = text as NSString
        let redacted = NSMutableString(string: text)
        for match in matches.reversed() where match.numberOfRanges >= 4 {
            let key = original.substring(with: match.range(at: 2))
            guard isSecretKey(key) else { continue }

            redacted.replaceCharacters(in: match.range(at: 3), with: tokenPlaceholder)
        }
        return redacted as String
    }

    private static func isSecretKey(_ key: String) -> Bool {
        let compactKey = key.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return secretKeyNeedles.contains { compactKey.contains($0) }
    }
}
