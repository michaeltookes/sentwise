import AppKit
import SwiftUI

/// Routes the application menu's Settings… command (and Command-comma) to the
/// one real Settings window, `SettingsWindowController` (backlog item 140).
///
/// `MenuBarController` registers the handler at launch; until then (or if it is
/// ever missing) the command does nothing rather than showing an empty window.
@MainActor
final class SettingsCommandRouter {
    static let shared = SettingsCommandRouter()

    /// Shows the tabbed Settings window. Set by `MenuBarController`.
    var handler: (() -> Void)?

    /// Invoked by the app-menu Settings… command. Returns whether it was handled.
    @discardableResult
    func openSettings() -> Bool {
        guard let handler else { return false }
        handler()
        return true
    }
}

/// Content of the SwiftUI `Settings` scene SwiftUI requires. The app-menu
/// command is replaced (see `SentwiseApp`), so this scene should never appear;
/// if it ever does, it hands off to the real window and closes itself instead
/// of presenting an empty body.
struct SettingsSceneHandoffView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(SettingsSceneCloser())
    }
}

private struct SettingsSceneCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            SettingsCommandRouter.shared.openSettings()
            view?.window?.close()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
