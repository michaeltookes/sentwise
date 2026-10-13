import AppKit
import SentwiseMail
import ServiceManagement
import XCTest
@testable import Sentwise

/// Status-to-UI mapping for "Launch at login" (item 113): a login item the user
/// disabled in System Settings reports `.requiresApproval`, which must keep the
/// toggle on and explain how to fix it instead of silently snapping off.
@MainActor
final class LaunchAtLoginStateTests: XCTestCase {

    private let caption = "macOS has disabled Sentwise in Login Items. Turn it back on in System Settings."

    // MARK: - SMAppService.Status mapping

    func testStatusMapping() {
        XCTAssertEqual(LaunchAtLoginState(status: .enabled), .enabled)
        XCTAssertEqual(LaunchAtLoginState(status: .requiresApproval), .requiresApproval)
        XCTAssertEqual(LaunchAtLoginState(status: .notRegistered), .notRegistered)
        XCTAssertEqual(LaunchAtLoginState(status: .notFound), .notFound)
    }

    // MARK: - UI mapping per status

    func testEnabledRendersOnWithoutCaption() {
        let state = LaunchAtLoginState(status: .enabled)
        XCTAssertTrue(state.isToggleOn)
        XCTAssertNil(state.caption)
        XCTAssertFalse(state.showsOpenLoginItemsAction)
        XCTAssertEqual(state.menuItemState, .on)
    }

    func testRequiresApprovalStaysOnWithCaptionAndAction() {
        let state = LaunchAtLoginState(status: .requiresApproval)
        XCTAssertTrue(state.isToggleOn)
        XCTAssertEqual(state.caption, caption)
        XCTAssertTrue(state.showsOpenLoginItemsAction)
        XCTAssertEqual(state.menuItemState, .on)
    }

    func testNotRegisteredRendersOffWithoutCaption() {
        let state = LaunchAtLoginState(status: .notRegistered)
        XCTAssertFalse(state.isToggleOn)
        XCTAssertNil(state.caption)
        XCTAssertFalse(state.showsOpenLoginItemsAction)
        XCTAssertEqual(state.menuItemState, .off)
    }

    func testNotFoundRendersOffWithoutCaption() {
        let state = LaunchAtLoginState(status: .notFound)
        XCTAssertFalse(state.isToggleOn)
        XCTAssertNil(state.caption)
        XCTAssertFalse(state.showsOpenLoginItemsAction)
        XCTAssertEqual(state.menuItemState, .off)
    }

    func testSpecStrings() {
        XCTAssertEqual(LaunchAtLoginState.requiresApprovalCaption, caption)
        XCTAssertEqual(LaunchAtLoginState.openLoginItemsTitle, "Open Login Items…")
        XCTAssertEqual(
            LaunchAtLoginState.loginItemsSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        )
    }

    // MARK: - AppState wiring

    private func makeAppState() -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(settings: .default),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            notifier: FakeDraftNotifier()
        )
    }

    func testTurningOnIntoRequiresApprovalKeepsToggleOn() {
        let app = makeAppState()
        var registered: [Bool] = []
        app.setLaunchAtLoginHandler = { registered.append($0); return true }
        app.launchAtLoginStatusProvider = { .requiresApproval }

        XCTAssertTrue(app.setLaunchAtLogin(true))

        XCTAssertEqual(registered, [true])
        XCTAssertEqual(app.launchAtLoginState, .requiresApproval)
        XCTAssertTrue(app.launchAtLogin)
    }

    func testRefreshPicksUpApprovalFromSystemSettings() {
        let app = makeAppState()
        app.launchAtLoginStatusProvider = { .requiresApproval }
        app.refreshLaunchAtLoginState()
        XCTAssertEqual(app.launchAtLoginState, .requiresApproval)

        app.launchAtLoginStatusProvider = { .enabled }
        app.refreshLaunchAtLoginState()
        XCTAssertEqual(app.launchAtLoginState, .enabled)
        XCTAssertNil(app.launchAtLoginState.caption)
    }

    func testOpenLoginItemsSettingsUsesHandler() {
        let app = makeAppState()
        var opened = 0
        app.openLoginItemsSettingsHandler = { opened += 1 }
        app.openLoginItemsSettings()
        XCTAssertEqual(opened, 1)
    }
}
