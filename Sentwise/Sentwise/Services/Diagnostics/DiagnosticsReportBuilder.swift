import Foundation

/// Assembles the final diagnostics report text from a context header and the
/// captured log entries, then runs the whole thing through the redactor
/// (item 36).
///
/// The output is plain UTF-8 text meant to be attached to a feedback email. It is
/// deliberately human-readable so the maintainer can skim it and a wary user can
/// read exactly what they're sending.
enum DiagnosticsReportBuilder {

    /// A fixed, ISO-8601 formatter so entry timestamps are stable and locale-free.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Builds the redacted report. `generatedAt` stamps the header; `entries` are
    /// the captured (already level-filtered) log lines, oldest-to-newest.
    static func build(
        context: DiagnosticsContext,
        entries: [DiagnosticsLogEntry],
        generatedAt: Date = Date()
    ) -> String {
        let header = """
        Sentwise diagnostics
        Generated: \(timestampFormatter.string(from: generatedAt))

        This report is redacted: email addresses and tokens are removed. It contains
        no message bodies, subjects, recipients, credentials, or account email.
        """

        let logSection: String
        if entries.isEmpty {
            logSection = "(no recent log entries)"
        } else {
            logSection = entries.map(format).joined(separator: "\n")
        }

        let raw = [
            header,
            "--- Environment ---",
            context.render(),
            "--- Recent logs (\(entries.count)) ---",
            logSection
        ].joined(separator: "\n\n")

        return DiagnosticsRedactor.redact(raw)
    }

    /// Formats one entry as `TIMESTAMP [LEVEL] category: message`.
    private static func format(_ entry: DiagnosticsLogEntry) -> String {
        let timestamp = timestampFormatter.string(from: entry.date)
        return "\(timestamp) [\(entry.level.rawValue)] \(entry.category): \(entry.message)"
    }
}
