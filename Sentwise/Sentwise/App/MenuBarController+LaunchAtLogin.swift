import AppKit

/// Status-menu "Launch at Login" item (item 113). Mirrors the Settings toggle:
/// a `.requiresApproval` login item stays checked and gets an explanatory row
/// plus an "Open Login Items…" action.
extension MenuBarController {

    func launchAtLoginMenuItems() -> [NSMenuItem] {
        let state = appState.launchAtLoginState
        var items: [NSMenuItem] = []

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = state.menuItemState
        login.setAccessibilityIdentifier("launchAtLogin")
        items.append(login)

        if let caption = state.caption {
            let note = NSMenuItem(title: caption, action: nil, keyEquivalent: "")
            note.isEnabled = false
            note.indentationLevel = 1
            note.setAccessibilityIdentifier("launchAtLoginApprovalCaption")
            items.append(note)
        }
        if state.showsOpenLoginItemsAction {
            let open = NSMenuItem(
                title: LaunchAtLoginState.openLoginItemsTitle,
                action: #selector(openLoginItemsSettingsMenu),
                keyEquivalent: ""
            )
            open.target = self
            open.indentationLevel = 1
            open.setAccessibilityIdentifier("openLoginItemsSettings")
            items.append(open)
        }
        return items
    }

    @objc private func toggleLaunchAtLogin() {
        appState.setLaunchAtLogin(!appState.launchAtLogin)
    }

    @objc private func openLoginItemsSettingsMenu() {
        appState.openLoginItemsSettings()
    }
}
