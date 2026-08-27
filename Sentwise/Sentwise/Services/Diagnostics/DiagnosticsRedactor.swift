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

    /// Matches an RFC-shaped email address, case-insensitively.
    private static let emailPattern =
        #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#

    /// Matches `Bearer <token>` (keeps the `Bearer` label, drops the value).
    private static let bearerPattern =
        #"(?i)(bearer)\s+[A-Za-z0-9._\-]{6,}"#

    /// Alternation of key names that name a secret.
    private static let secretKeys =
        "authorization|api[_-]?key|apikey|password|passwd|secret|token"
        + "|access[_-]?token|refresh[_-]?token|client[_-]?token|session[_-]?id"

    /// Matches a `key: value` / `key=value` pair whose key names a secret, so an
    /// inline `token=…`, `apiKey=…`, `password=…`, or `authorization: …` value is
    /// scrubbed even when the value itself doesn't look like an email or bearer.
    private static let secretAssignmentPattern =
        #"(?i)\b("# + secretKeys + #")\b(\s*[:=]\s*)\S+"#

    /// Common absolute path roots in app/unified-log output. Keep this scoped so
    /// ordinary punctuation or URL paths are not treated as filesystem paths.
    private static let pathRootPattern =
        "(Users|Volumes|private|var|tmp|Applications|Library|System|opt|etc|usr|bin|sbin|home)"

    /// Matches quoted absolute paths, preserving the opening quote.
    private static let quotedPathPattern =
        #"(?m)(["'`])/"# + pathRootPattern + #"([^"'`\r\n]*)"#

    /// Matches log phrases ending with `: /absolute/path`, including filenames
    /// with spaces through the end of that log line.
    private static let colonPathPattern =
        #"(?m)(:\s*)/"# + pathRootPattern + #"([^\r\n]*)"#

    /// Matches compact `path=/absolute/path` / `file: /absolute/path` fields.
    private static let labeledPathPattern =
        #"(?i)\b(path|file|folder|directory|seenKey|key)(\s*[:=]\s*)/"#
        + pathRootPattern
        + #"(\S+)"#

    /// Matches unquoted absolute paths in free-form errors, stopping before the
    /// next word so adjacent `token=...` style fields still get scrubbed as tokens.
    private static let barePathPattern =
        #"(?m)(^|[\s(])/"# + pathRootPattern + #"([^\s"'`,;)]+)"#

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
        result = result.replacingOccurrences(
            of: secretAssignmentPattern,
            with: "$1$2\(tokenPlaceholder)",
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
}
