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
