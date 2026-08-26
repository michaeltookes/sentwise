import AppKit
import Foundation

/// The side-effecting steps of "Report a Problem" — revealing the bundle in
/// Finder and opening the mail client — behind a seam so tests can drive the
/// orchestration without launching Finder or Mail (item 36).
///
/// Not actor-isolated so it can be used as a default argument; `reportAProblem`
/// only ever invokes it from the main actor, where `NSWorkspace` expects to run.
protocol DiagnosticsActionRouting {
    /// Reveals `url` in Finder (selects the file in its enclosing folder).
    func revealInFinder(_ url: URL)
    /// Opens `url` with the default handler (the `mailto:` URL → mail client).
    func open(_ url: URL)
}

/// Production router backed by `NSWorkspace`.
struct SystemDiagnosticsActionRouter: DiagnosticsActionRouting {
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
