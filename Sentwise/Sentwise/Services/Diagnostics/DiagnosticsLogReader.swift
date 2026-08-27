import Foundation
import OSLog

/// The coarse severity of a captured log entry, ordered from most to least
/// chatty. `debug`/`info` are the "verbose" tiers, only included when the user
/// has opted into verbose logging.
enum DiagnosticsLogLevel: String, Equatable, Sendable {
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
struct DiagnosticsLogEntry: Equatable, Sendable {
    let date: Date
    let category: String
    let level: DiagnosticsLogLevel
    let message: String
}

/// Reads the app's own recent log entries. Behind a protocol so the bundle
/// builder can be unit-tested with injected fake lines, never touching the real
/// unified log store.
protocol DiagnosticsLogReading: Sendable {
    /// Returns the app's own log entries since `date`, newest handling left to the
    /// caller. When `includingVerbose` is false, `debug`/`info` entries are
    /// omitted so a default bundle stays lean.
    func recentEntries(since date: Date, includingVerbose: Bool) throws -> [DiagnosticsLogEntry]
}

/// Bounded tail buffer for unified-log collection. Enumeration is oldest to
/// newest, so evict from the front when limits are reached to keep the newest
/// entries near the user's report action.
struct DiagnosticsLogTailBuffer {
    let maxEntries: Int
    let maxMessageBytes: Int
    private(set) var entries: [DiagnosticsLogEntry] = []
    private var collectedMessageBytes = 0

    init(maxEntries: Int, maxMessageBytes: Int) {
        self.maxEntries = maxEntries
        self.maxMessageBytes = maxMessageBytes
    }

    mutating func append(_ entry: DiagnosticsLogEntry) {
        guard maxEntries > 0, maxMessageBytes > 0 else { return }

        let messageBytes = entry.message.utf8.count
        guard messageBytes <= maxMessageBytes else { return }

        while entries.count >= maxEntries || collectedMessageBytes + messageBytes > maxMessageBytes {
            let removed = entries.removeFirst()
            collectedMessageBytes -= removed.message.utf8.count
        }

        entries.append(entry)
        collectedMessageBytes += messageBytes
    }
}

/// Testable wrapper for the `OSLogStore` scope used by diagnostics collection.
enum DiagnosticsLogStoreScope: Equatable, Sendable {
    case system
    case currentProcessIdentifier

    var osLogStoreScope: OSLogStore.Scope {
        switch self {
        case .system:
            return .system
        case .currentProcessIdentifier:
            return .currentProcessIdentifier
        }
    }
}

/// Production reader backed by `OSLogStore`, scoped to the system log and the
/// Sentwise subsystem so reports can include the app's prior launches without
/// collecting unrelated system noise.
struct OSLogStoreDiagnosticsReader: DiagnosticsLogReading {

    /// Upper bound for entries included in one report.
    static let defaultMaxEntries = 2_000

    /// Upper bound for captured log-message bytes included in one report.
    static let defaultMaxMessageBytes = 1_000_000

    /// Subsystem filter — only entries the app itself logged.
    let subsystem: String

    /// Log scope for collection. The default is system-wide so a relaunch after
    /// a crash can still recover the previous Sentwise process's entries.
    let scope: DiagnosticsLogStoreScope

    /// Maximum number of entries to collect before stopping enumeration.
    let maxEntries: Int

    /// Maximum total UTF-8 bytes across captured log messages.
    let maxMessageBytes: Int

    init(
        subsystem: String = DiagnosticLog.subsystem,
        scope: DiagnosticsLogStoreScope = .system,
        maxEntries: Int = Self.defaultMaxEntries,
        maxMessageBytes: Int = Self.defaultMaxMessageBytes
    ) {
        self.subsystem = subsystem
        self.scope = scope
        self.maxEntries = maxEntries
        self.maxMessageBytes = maxMessageBytes
    }

    func recentEntries(since date: Date, includingVerbose: Bool) throws -> [DiagnosticsLogEntry] {
        guard maxEntries > 0, maxMessageBytes > 0 else { return [] }

        let store = try OSLogStore(scope: scope.osLogStoreScope)
        let position = store.position(date: date)
        let predicate = Self.makePredicate(subsystem: subsystem)
        let enumerator = try store.getEntries(at: position, matching: predicate)

        var tail = DiagnosticsLogTailBuffer(
            maxEntries: maxEntries,
            maxMessageBytes: maxMessageBytes
        )
        for element in enumerator {
            guard let log = element as? OSLogEntryLog else { continue }
            let level = Self.map(log.level)
            if level.isVerboseOnly && !includingVerbose { continue }
            let message = log.composedMessage
            tail.append(
                DiagnosticsLogEntry(
                    date: log.date,
                    category: log.category,
                    level: level,
                    message: message
                )
            )
        }
        return tail.entries
    }

    static func makePredicate(subsystem: String) -> NSPredicate {
        NSPredicate(format: "subsystem == %@", subsystem)
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
