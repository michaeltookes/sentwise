import SwiftUI

/// Main entry point for Sentwise.
///
/// This is a menu bar application (`LSUIElement = YES`) that watches the user's
/// inbox, drafts replies in their voice, and surfaces them for approval.
/// All UI is driven from the `AppDelegate`; the `Settings` scene exists
/// only because SwiftUI requires at least one scene and it does not open a
/// default window at launch.
@main
struct SentwiseApp: App {
    /// Handles `NSApplication` lifecycle and menu-bar setup.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // SwiftUI requires a scene. Its own Settings… command is replaced below
        // so the app menu and Command-comma open the real tabbed window
        // (item 140); the scene's content hands off and closes if ever shown.
        SwiftUI.Settings {
            SettingsSceneHandoffView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsCommandRouter.shared.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
