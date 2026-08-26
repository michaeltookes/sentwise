import Foundation
import os

/// Lightweight façade over the unified log for developer diagnostics (item 36).
///
/// The whole point of the feedback channel is that a user can file an actionable
/// bug report *without leaking email content*. Nothing here ever logs message
/// bodies, subjects, or addresses — those are never passed to the logger at any
/// level. The verbosity flag only controls how much non-PII operational detail is
/// emitted (and, in turn, captured into the "Report a Problem" bundle).
///
/// `isVerbose` mirrors the persisted `Settings.verboseDiagnosticLogging` toggle.
/// `AppState` writes it on launch and whenever the user flips the toggle. It is a
/// plain global so free functions and value types (the diagnostics readers and
/// builders) can consult it without reaching into `AppState`.
enum DiagnosticLog {

    /// Whether verbose diagnostic logging is on. Off (normal) by default. Only
    /// ever set on the main actor from `AppState`; read cheaply from anywhere.
    static var isVerbose = false

    /// The subsystem every Sentwise `Logger` uses; the diagnostics reader scopes
    /// the log store to exactly this so unrelated system noise never enters a
    /// bundle.
    static let subsystem = "com.tookes.Sentwise"

    /// Shared logger for the diagnostics/feedback surface itself.
    static let logger = Logger(subsystem: subsystem, category: "Diagnostics")

    /// Emits an extra, non-PII operational detail *only* when verbose logging is
    /// on. In normal mode this is a no-op, so the default log (and therefore a
    /// default bundle) stays lean. Callers must never pass user content here.
    static func verbose(_ message: @autoclosure @escaping () -> String) {
        guard isVerbose else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }
}
