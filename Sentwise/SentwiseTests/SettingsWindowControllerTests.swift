import AppKit
import XCTest
@testable import Sentwise

@MainActor
final class SettingsWindowControllerTests: XCTestCase {

    func testShowRequestedTabDoesNotBuildRememberedPaneWhenOpeningWindow() {
        let appState = AppState(
            persistence: AppStateMemoryPersistence(settings: Settings.default),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        let controller = SettingsWindowController(appState: appState, updateManager: UpdateManager())
        controller.show(tab: .subscription)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        controller.show(tab: .ai)

        XCTAssertEqual(appState.activeSettingsTab, .ai)
        XCTAssertEqual(controller.cachedPaneTabs, [.ai])
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }
}

@MainActor
final class SettingsCommandRouterTests: XCTestCase {

    func testAppMenuCommandReachesSettingsWindowController() {
        let appState = AppState(
            persistence: AppStateMemoryPersistence(settings: Settings.default),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        let controller = SettingsWindowController(appState: appState, updateManager: UpdateManager())
        let router = SettingsCommandRouter()
        var shows = 0
        // Same wiring MenuBarController installs.
        router.handler = { controller.show(); shows += 1 }

        XCTAssertTrue(router.openSettings())
        XCTAssertTrue(router.openSettings())

        XCTAssertEqual(shows, 2)
        // Second invocation reuses the one window; General is first.
        XCTAssertEqual(appState.activeSettingsTab, .general)
        XCTAssertEqual(controller.cachedPaneTabs, [.general])
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    func testCommandWithoutHandlerShowsNothing() {
        XCTAssertFalse(SettingsCommandRouter().openSettings())
    }
}
