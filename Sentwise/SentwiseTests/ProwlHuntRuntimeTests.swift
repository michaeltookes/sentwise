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
    /// omit XCTestConfigurationFilePath and set these keys instead; each one on
    /// its own must flip the host app into isolated hunt mode (item 115).
    func testEnablesFromEveryXCTestSessionEnvironmentKey() {
        for key in ProwlHuntRuntime.xctestSessionEnvironmentKeys {
            XCTAssertTrue(ProwlHuntRuntime.isEnabled(
                environment: [key: "some-non-empty-value"],
                arguments: [],
                bundlePath: "/Applications/Sentwise.app"
            ), "expected \(key) alone to enable the isolated test runtime")
        }
    }

    func testEmptyXCTestSessionEnvironmentValuesDoNotEnable() {
        var environment: [String: String] = [:]
        for key in ProwlHuntRuntime.xctestSessionEnvironmentKeys {
            environment[key] = ""
        }
        XCTAssertFalse(ProwlHuntRuntime.isEnabled(
            environment: environment,
            arguments: [],
            bundlePath: "/Applications/Sentwise.app"
        ))
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
