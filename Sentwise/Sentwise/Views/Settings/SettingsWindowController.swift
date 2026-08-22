import AppKit
import SwiftUI

/// The Settings window's tabs (item 65). Each case maps a native `NSToolbar`
/// item — an SF Symbol plus label — to a SwiftUI pane, mirroring the ContainerBar
/// settings architecture: a fixed-size window with a System Settings–style
/// preference toolbar hosting grouped-form panes.
///
/// The raw value doubles as the toolbar label and the window title (which follows
/// the selected tab). The window's accessibility *label* is separate and stays
/// `"Sentwise Settings"` so the Prowl `settings-window` hunt keeps matching it.
enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general = "General"
    case account = "Account"
    case ai = "AI"
    case rules = "Rules"
    case about = "About"

    var id: String { rawValue }

    /// SF Symbol shown for the tab in the toolbar.
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .account: return "envelope"
        case .ai: return "sparkles"
        case .rules: return "line.3.horizontal.decrease.circle"
        case .about: return "info.circle"
        }
    }

    var toolbarItemIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(rawValue)
    }
}

/// Hosts the SwiftUI pane for the selected tab. Reuses the existing per-tab pane
/// views unchanged, so all settings logic (bindings, persistence, validation)
/// stays in one place and only the surrounding window chrome is new.
struct SettingsContentView: View {
    let selectedTab: SettingsTab
    let updateManager: UpdateManager

    var body: some View {
        Group {
            switch selectedTab {
            case .general:
                GeneralSettingsView()
            case .account:
                EmailAccountSettingsView()
            case .ai:
                AIProviderSettingsView()
            case .rules:
                SenderRulesSettingsView()
            case .about:
                AboutPane(updateManager: updateManager)
            }
        }
        .frame(
            width: SettingsWindowController.contentSize.width,
            height: SettingsWindowController.contentSize.height
        )
    }
}

/// Keeps each SwiftUI settings pane hosted while the window is open so tab
/// switches do not reset pane-local `@State`.
@MainActor
final class SettingsPaneControllerCache {
    private let makeRootView: (SettingsTab) -> AnyView
    private var controllers: [SettingsTab: NSHostingController<AnyView>] = [:]

    init(makeRootView: @escaping (SettingsTab) -> AnyView) {
        self.makeRootView = makeRootView
    }

    var cachedTabCount: Int {
        controllers.count
    }

    func controller(for tab: SettingsTab) -> NSHostingController<AnyView> {
        if let controller = controllers[tab] {
            return controller
        }

        let controller = NSHostingController(rootView: makeRootView(tab))
        // Panes scroll internally; the window is a fixed size. Stop the hosting
        // controller from resizing the window to each pane's fitting size, which
        // made the window jump/collapse when switching tabs.
        controller.sizingOptions = []
        controller.preferredContentSize = SettingsWindowController.contentSize
        controllers[tab] = controller
        return controller
    }

    func removeAll() {
        controllers.removeAll()
    }
}

/// Owns the Settings window and its native toolbar (item 65). Replaces the old
/// SwiftUI `TabView`-in-a-window with a `NSToolbar` of tab icons plus an
/// `NSHostingController` cached per tab — the pattern proven in ContainerBar and
/// used by System Settings and other polished menu-bar apps.
///
/// One instance is owned by `MenuBarController`; `AppState` and `UpdateManager`
/// are injected at construction so panes and the About tab keep the app's single
/// state container and updater.
@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {

    /// Fixed content size for every pane. The panes are grouped `Form`s that
    /// scroll internally when their content is taller than this, so the window
    /// stays a fixed, non-resizable size like a native Settings window.
    static let contentSize = CGSize(width: 560, height: 480)

    private let appState: AppState
    private let updateManager: UpdateManager

    private var window: NSWindow?
    private lazy var paneControllerCache = SettingsPaneControllerCache { [appState, updateManager] tab in
        AnyView(
            SettingsContentView(selectedTab: tab, updateManager: updateManager)
                .environmentObject(appState)
        )
    }
    private var selectedTab: SettingsTab = .general

    init(appState: AppState, updateManager: UpdateManager) {
        self.appState = appState
        self.updateManager = updateManager
        super.init()
    }

    /// Shows the Settings window, creating it lazily. Reopening returns to the
    /// last-selected tab.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = selectedTab.rawValue
        // The visible title follows the selected tab, but the accessibility label
        // stays constant so the Prowl `settings-window` hunt (item 65) keeps
        // matching `label="Sentwise Settings"`. Do not change this string.
        window.setAccessibilityLabel("Sentwise Settings")
        window.isReleasedWhenClosed = false

        let toolbar = NSToolbar(identifier: "SentwiseSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = selectedTab.toolbarItemIdentifier
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        window.contentViewController = paneControllerCache.controller(for: selectedTab)

        window.center()
        window.setFrameAutosaveName("SentwiseSettingsWindow")

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateContent(for tab: SettingsTab) {
        guard tab != selectedTab else {
            window?.title = tab.rawValue
            return
        }

        selectedTab = tab
        // Swapping the content view controller lets AppKit re-place the window
        // (each pane is a hosting controller); pin the top-left corner across the
        // swap so switching tabs never moves the window.
        let topLeft = window.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        window?.contentViewController = paneControllerCache.controller(for: tab)
        window?.setContentSize(Self.contentSize)
        if let topLeft { window?.setFrameTopLeftPoint(topLeft) }
        window?.title = tab.rawValue
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Drop the window/hosting controllers so the next open rebuilds them; keep
        // `selectedTab` so reopening returns to the tab the user last viewed.
        window = nil
        paneControllerCache.removeAll()
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { $0.toolbarItemIdentifier }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { $0.toolbarItemIdentifier }
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { $0.toolbarItemIdentifier }
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab.allCases.first(where: { $0.toolbarItemIdentifier == itemIdentifier }) else {
            return nil
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.rawValue
        item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.rawValue)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        item.isNavigational = false
        return item
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab.allCases.first(where: { $0.toolbarItemIdentifier == sender.itemIdentifier }) else {
            return
        }
        window?.toolbar?.selectedItemIdentifier = tab.toolbarItemIdentifier
        updateContent(for: tab)
    }
}
