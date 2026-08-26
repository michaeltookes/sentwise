import Foundation
import OSLog

/// The coarse severity of a captured log entry, ordered from most to least
/// chatty. `debug`/`info` are the "verbose" tiers, only included when the user
/// has opted into verbose logging.
enum DiagnosticsLogLevel: String, Equatable {
    case debug
    case info
    case notice
    case error
    case fault

    /// Whether this level is only surfaced under verbose logging.
    var isVerboseOnly: Bool {
        self == .debug || self == .info
    }
}

/// One captured log line, reduced to the non-PII fields the bundle needs.
struct DiagnosticsLogEntry: Equatable {
    let date: Date
    let category: String
    let level: DiagnosticsLogLevel
    let message: String
}

/// Reads the app's own recent log entries. Behind a protocol so the bundle
/// builder can be unit-tested with injected fake lines, never touching the real
/// unified log store.
protocol DiagnosticsLogReading {
    /// Returns the app's own log entries since `date`, newest handling left to the
    /// caller. When `includingVerbose` is false, `debug`/`info` entries are
    /// omitted so a default bundle stays lean.
    func recentEntries(since date: Date, includingVerbose: Bool) throws -> [DiagnosticsLogEntry]
}

/// Production reader backed by `OSLogStore`, scoped to the current process and
/// the Sentwise subsystem so only the app's own entries are read.
struct OSLogStoreDiagnosticsReader: DiagnosticsLogReading {

    /// Subsystem filter — only entries the app itself logged.
    let subsystem: String

    init(subsystem: String = DiagnosticLog.subsystem) {
        self.subsystem = subsystem
    }

    func recentEntries(since date: Date, includingVerbose: Bool) throws -> [DiagnosticsLogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: date)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        let enumerator = try store.getEntries(at: position, matching: predicate)

        var entries: [DiagnosticsLogEntry] = []
        for element in enumerator {
            guard let log = element as? OSLogEntryLog else { continue }
            let level = Self.map(log.level)
            if level.isVerboseOnly && !includingVerbose { continue }
            entries.append(
                DiagnosticsLogEntry(
                    date: log.date,
                    category: log.category,
                    level: level,
                    message: log.composedMessage
                )
            )
        }
        return entries
    }

    static func map(_ level: OSLogEntryLog.Level) -> DiagnosticsLogLevel {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .notice
        case .error: return .error
        case .fault: return .fault
        case .undefined: return .notice
        @unknown default: return .notice
        }
    }
}
