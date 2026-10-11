import XCTest
@testable import Sentwise

final class ProwlHuntRuntimeTests: XCTestCase {

    func testEnablesFromEnvironmentFlag() {
        XCTAssertTrue(ProwlHuntRuntime.isEnabled(
            environment: [ProwlHuntRuntime.environmentKey: "1"],
            arguments: [],
            bundlePath: "/Applications/Sentwise.app"
        ))
    }

    func testEnablesFromLaunchArgument() {
        XCTAssertTrue(ProwlHuntRuntime.isEnabled(
            environment: [:],
            arguments: ["Sentwise", ProwlHuntRuntime.launchArgument],
            bundlePath: "/Applications/Sentwise.app"
        ))
    }

    func testEnablesFromXCTestConfiguration() {
        XCTAssertTrue(ProwlHuntRuntime.isEnabled(
            environment: [ProwlHuntRuntime.xctestConfigurationEnvironmentKey: "/tmp/SentwiseTests.xctestconfiguration"],
            arguments: [],
            bundlePath: "/Applications/Sentwise.app"
        ))
    }

    /// Newer xcodebuild test sessions (test-without-building under recent Xcode)
    /// omit XCTestConfigurationFilePath and set session/bundle keys instead; each
    /// one on its own must mark the launch as test-hosted (item 115).
    func testDetectsXCTestHostLaunchFromEverySessionEnvironmentKey() {
        for key in ProwlHuntRuntime.xctestSessionEnvironmentKeys {
            XCTAssertTrue(
                ProwlHuntRuntime.isXCTestHostLaunch(environment: [key: "some-non-empty-value"]),
                "expected \(key) alone to mark an XCTest-hosted launch"
            )
        }
    }

    func testEmptyXCTestSessionEnvironmentValuesAreNotATestHostLaunch() {
        var environment: [String: String] = [:]
        for key in ProwlHuntRuntime.xctestSessionEnvironmentKeys {
            environment[key] = ""
        }
        XCTAssertFalse(ProwlHuntRuntime.isXCTestHostLaunch(environment: environment))
    }

    /// An XCTest-hosted launch must NOT flip hunt mode itself — hunt mode
    /// changes app behavior that unit tests encode. Only the app delegate's
    /// boot decision (`launchRuntime`) isolates the test host.
    func testSessionKeysAloneDoNotEnableHuntMode() {
        XCTAssertFalse(ProwlHuntRuntime.isEnabled(
            environment: ["XCTestSessionIdentifier": "ABC-123"],
            arguments: [],
            bundlePath: "/Applications/Sentwise.app"
        ))
    }

    func testLaunchRuntimeIsIsolatedForXCTestHostLaunch() {
        for key in ProwlHuntRuntime.xctestSessionEnvironmentKeys {
            XCTAssertTrue(ProwlHuntRuntime.launchRuntime(
                environment: [key: "some-non-empty-value"],
                arguments: [],
                bundlePath: "/Applications/Sentwise.app"
            ).isEnabled, "expected \(key) alone to isolate the boot runtime")
        }
    }

    func testLaunchRuntimeIsIsolatedForHuntMode() {
        XCTAssertTrue(ProwlHuntRuntime.launchRuntime(
            environment: [ProwlHuntRuntime.environmentKey: "1"],
            arguments: [],
            bundlePath: "/Applications/Sentwise.app"
        ).isEnabled)
    }

    func testLaunchRuntimeIsLiveForARegularLaunch() {
        XCTAssertFalse(ProwlHuntRuntime.launchRuntime(
            environment: [:],
            arguments: [],
            bundlePath: "/Applications/Sentwise.app"
        ).isEnabled)
    }

    func testEnablesFromDocumentedProwlDerivedDataBundlePath() {
        XCTAssertTrue(ProwlHuntRuntime.isEnabled(
            environment: [:],
            arguments: [],
            bundlePath: "/repo/.prowl/DerivedData/Build/Products/Debug/Sentwise.app"
        ))
    }

    func testDoesNotEnableForRegularDerivedDataBundlePath() {
        XCTAssertFalse(ProwlHuntRuntime.isEnabled(
            environment: [:],
            arguments: [],
            bundlePath: "/Users/me/Library/Developer/Xcode/DerivedData/Sentwise.app"
        ))
    }

    func testProwlRuntimeUsesIsolatedStoresAndDisablesStartupSideEffects() {
        let runtime = ProwlHuntRuntime(isEnabled: true)

        XCTAssertFalse(runtime.allowsStartupSideEffects)
        XCTAssertFalse(runtime.shouldOpenOnboardingAtLaunch)
        XCTAssertTrue(runtime.makePersistenceProvider() is MemoryPersistenceProvider)
        XCTAssertTrue(runtime.makeSecretStore() is InMemorySecretStore)
    }

    func testProwlRuntimeSeedsConnectedFixtureAccount() throws {
        let runtime = ProwlHuntRuntime(isEnabled: true)
        let persistence = runtime.makePersistenceProvider()
        let secrets = runtime.makeSecretStore()

        let settings = persistence.loadSettings()
        XCTAssertEqual(settings.mailEmail, ProwlHuntRuntime.fixtureAccountEmail)
        XCTAssertEqual(settings.savedAccounts.map(\.id), [ProwlHuntRuntime.fixtureAccountEmail])
        XCTAssertTrue(settings.onboardingCompleted)
        // The fixture must never be able to reach a real server or LLM.
        XCTAssertTrue(settings.mailHost.hasSuffix(".invalid"))
        XCTAssertTrue(ProwlHuntRuntime.fixtureAccountEmail.hasSuffix(".invalid"))
        XCTAssertTrue(settings.llmVerifiedModel.isEmpty)

        let password = try secrets.value(
            for: .mailAppPassword(email: ProwlHuntRuntime.fixtureAccountEmail)
        )
        XCTAssertEqual(password, ProwlHuntRuntime.fixtureAppPassword)

        let drafts = persistence.loadPendingDrafts()
        XCTAssertEqual(drafts.map(\.sourceSubject), ["Prowl hunt fixture"])
    }

    @MainActor
    func testAppStateWithSeededFixtureExposesAccountGatedMenuSurfaces() {
        let runtime = ProwlHuntRuntime(isEnabled: true)
        let appState = AppState(
            persistence: runtime.makePersistenceProvider(),
            secrets: runtime.makeSecretStore(),
            notifier: NullDraftNotifier()
        )

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertTrue(appState.hasReviewWindowContent)
        XCTAssertFalse(appState.canWatch)
    }

    func testProductionRuntimeUsesLiveStoresAndStartupSideEffects() {
        let runtime = ProwlHuntRuntime(isEnabled: false)

        XCTAssertTrue(runtime.allowsStartupSideEffects)
        XCTAssertTrue(runtime.shouldOpenOnboardingAtLaunch)
        XCTAssertFalse(runtime.makePersistenceProvider() is MemoryPersistenceProvider)
        XCTAssertTrue(runtime.makeSecretStore() is KeychainStore)
    }
}
