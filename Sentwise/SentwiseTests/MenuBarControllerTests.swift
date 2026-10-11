import AppKit
import XCTest
@testable import Sentwise

/// Item 112: the menu-bar status item must be locatable by name in the
/// accessibility tree. On macOS 26, Control Center hosts third-party status
/// items, and the NSImage's accessibility description does not propagate to
/// the hosted item — the button itself must carry the label and identifier.
@MainActor
final class MenuBarControllerTests: XCTestCase {

    private func makeController() -> MenuBarController {
        let appState = AppState(
            persistence: AppStateMemoryPersistence(settings: Settings.default),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        return MenuBarController(appState: appState, updateManager: UpdateManager())
    }

    func testStatusItemButtonCarriesAccessibilityIdentifierAndLabel() throws {
        let controller = makeController()
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }

        let button = try XCTUnwrap(controller.statusItem.button)
        XCTAssertEqual(button.accessibilityIdentifier(), "sentwise.statusItem")
        XCTAssertEqual(button.accessibilityLabel(), "Sentwise")
    }

    func testStatusItemHasAutosaveName() {
        let controller = makeController()
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }

        XCTAssertEqual(controller.statusItem.autosaveName, "Sentwise")
    }
}
