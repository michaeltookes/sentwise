import AppKit
import XCTest
@testable import Sentwise

/// Item 113: the status-menu "Launch at Login" item mirrors the Settings toggle,
/// including the approval caption and "Open Login Items…" action.
@MainActor
final class MenuBarControllerLaunchAtLoginTests: XCTestCase {

    private func makeController(state: LaunchAtLoginState) -> MenuBarController {
        let appState = AppState(
            persistence: AppStateMemoryPersistence(settings: Settings.default),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        appState.launchAtLoginStatusProvider = { state }
        appState.refreshLaunchAtLoginState()
        return MenuBarController(appState: appState, updateManager: UpdateManager())
    }

    private func ids(_ items: [NSMenuItem]) -> [String] {
        items.map { $0.accessibilityIdentifier() }
    }

    func testRequiresApprovalShowsCheckedItemCaptionAndAction() throws {
        let controller = makeController(state: .requiresApproval)
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }

        let items = controller.launchAtLoginMenuItems()
        XCTAssertEqual(ids(items), ["launchAtLogin", "launchAtLoginApprovalCaption", "openLoginItemsSettings"])
        XCTAssertEqual(items[0].state, .on)
        XCTAssertEqual(items[1].title, LaunchAtLoginState.requiresApprovalCaption)
        XCTAssertFalse(items[1].isEnabled)
        XCTAssertEqual(items[2].title, "Open Login Items…")
    }

    func testEnabledShowsCheckedItemOnly() {
        let controller = makeController(state: .enabled)
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }

        let items = controller.launchAtLoginMenuItems()
        XCTAssertEqual(ids(items), ["launchAtLogin"])
        XCTAssertEqual(items[0].state, .on)
    }

    func testNotRegisteredAndNotFoundShowUncheckedItemOnly() {
        for state in [LaunchAtLoginState.notRegistered, .notFound] {
            let controller = makeController(state: state)
            let items = controller.launchAtLoginMenuItems()
            XCTAssertEqual(ids(items), ["launchAtLogin"], "\(state)")
            XCTAssertEqual(items[0].state, .off, "\(state)")
            NSStatusBar.system.removeStatusItem(controller.statusItem)
        }
    }
}
