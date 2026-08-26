import XCTest
@testable import Sentwise

/// Tests for surfacing a disabled notification permission (item 78). When macOS
/// "Allow Notifications" is off, posted draft notifications are silently dropped,
/// so the app must detect the status and flag it — without nagging when it's on.
@MainActor
final class AppStateNotificationPermissionTests: XCTestCase {

    private func makeAppState(
        notifier: FakeDraftNotifier
    ) -> AppState {
        let secrets = InMemorySecretStore(seed: [:])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com"
        ))
        return AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            notifier: notifier
        )
    }

    func testDefaultsToAuthorizedSoNothingNagsBeforeFirstCheck() {
        let appState = makeAppState(notifier: FakeDraftNotifier())
        XCTAssertEqual(appState.notificationPermission, .authorized)
        XCTAssertFalse(appState.notificationsBlocked)
    }

    func testDeniedPermissionMarksNotificationsBlocked() async {
        let notifier = FakeDraftNotifier()
        notifier.authorizationStatus = .denied
        let appState = makeAppState(notifier: notifier)

        await appState.refreshNotificationPermission()

        XCTAssertEqual(appState.notificationPermission, .denied)
        XCTAssertTrue(appState.notificationsBlocked)
    }

    func testAuthorizedPermissionClearsTheBlock() async {
        let notifier = FakeDraftNotifier()
        notifier.authorizationStatus = .denied
        let appState = makeAppState(notifier: notifier)
        await appState.refreshNotificationPermission()
        XCTAssertTrue(appState.notificationsBlocked)

        // The user turned notifications back on; a later re-check clears the hint.
        notifier.authorizationStatus = .authorized
        await appState.refreshNotificationPermission()

        XCTAssertEqual(appState.notificationPermission, .authorized)
        XCTAssertFalse(appState.notificationsBlocked)
    }

    func testNotDeterminedIsBlockedAndReRequestsAuthorization() async {
        let notifier = FakeDraftNotifier()
        notifier.authorizationStatus = .notDetermined
        let appState = makeAppState(notifier: notifier)

        await appState.refreshNotificationPermission()

        XCTAssertEqual(appState.notificationPermission, .notDetermined)
        XCTAssertTrue(appState.notificationsBlocked)
        // notDetermined still prompts, so the app re-requests authorization.
        XCTAssertTrue(notifier.authorizationRequested)
    }

    func testNotDeterminedRefreshesStatusAfterAuthorizationRequest() async {
        let notifier = FakeDraftNotifier()
        notifier.authorizationStatus = .notDetermined
        notifier.authorizationStatusAfterRequest = .authorized
        let appState = makeAppState(notifier: notifier)

        await appState.refreshNotificationPermission()

        XCTAssertTrue(notifier.authorizationRequested)
        XCTAssertEqual(notifier.authorizationStatusChecks, 2)
        XCTAssertEqual(appState.notificationPermission, .authorized)
        XCTAssertFalse(appState.notificationsBlocked)
    }

    func testDeniedDoesNotReRequestAuthorization() async {
        let notifier = FakeDraftNotifier()
        notifier.authorizationStatus = .denied
        let appState = makeAppState(notifier: notifier)

        await appState.refreshNotificationPermission()

        // macOS won't re-prompt once denied; the app must guide to System Settings
        // instead of firing a no-op request.
        XCTAssertFalse(notifier.authorizationRequested)
    }

    func testNotificationSettingsURLTargetsSentwiseBundle() throws {
        let url = try XCTUnwrap(URL(string: AppState.notificationSettingsURLString))

        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(AppState.notificationSettingsURLString.contains("?id=com.tookes.Sentwise"))
    }
}
