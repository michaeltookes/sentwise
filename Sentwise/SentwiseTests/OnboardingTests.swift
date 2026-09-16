import XCTest
@testable import Sentwise

/// Tests for the first-run onboarding transitions on `AppState` (item 2).
///
/// These exercise the flow's logic — resume-step derivation, the
/// already-configured reconcile rule, and completion — at the `AppState`
/// level with in-memory fakes, not the SwiftUI view.
@MainActor
final class OnboardingTests: XCTestCase {

    // MARK: - Builders

    private func connectedSettings(
        schemaVersion: Int = Settings.currentSchemaVersion,
        onboardingCompleted: Bool = false
    ) -> Settings {
        Settings(
            schemaVersion: schemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            onboardingCompleted: onboardingCompleted
        )
    }

    /// An AppState with both an account and an LLM connected.
    private func makeFullyConnected(
        schemaVersion: Int = Settings.currentSchemaVersion,
        onboardingCompleted: Bool = false
    )
        -> (AppState, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: connectedSettings(
                schemaVersion: schemaVersion,
                onboardingCompleted: onboardingCompleted
            )
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        return (appState, persistence)
    }

    /// An AppState with an account connected but no verified LLM.
    private func makeAccountOnly() -> (AppState, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [.mailAppPassword: "app-pw"])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com"
            )
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        return (appState, persistence)
    }

    /// An AppState with nothing connected.
    private func makeDisconnected(onboardingCompleted: Bool = false)
        -> (AppState, AppStateMemoryPersistence) {
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                onboardingCompleted: onboardingCompleted
            )
        )
        let appState = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        return (appState, persistence)
    }

    // MARK: - Resume step

    func testResumeStepIsConnectAccountWhenNothingConnected() {
        let (appState, _) = makeDisconnected()
        XCTAssertEqual(appState.onboardingResumeStep, .connectAccount)
    }

    func testResumeStepIsConnectProviderWhenOnlyAccountConnected() {
        let (appState, _) = makeAccountOnly()
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.onboardingResumeStep, .connectProvider)
    }

    func testResumeStepIsSendBehaviorWhenFullyConnected() {
        let (appState, _) = makeFullyConnected()
        XCTAssertTrue(appState.canFinishOnboarding)
        XCTAssertEqual(appState.onboardingResumeStep, .sendBehavior)
    }

    // MARK: - Continue-disabled helper text

    func testConnectStepsExplainWhyContinueIsDisabledWhenNothingConnected() {
        let (appState, _) = makeDisconnected()

        XCTAssertEqual(
            appState.onboardingContinueBlockedReason(for: .connectAccount),
            "Run Test Connection to continue."
        )
        XCTAssertEqual(
            appState.onboardingContinueBlockedReason(for: .connectProvider),
            "Sign in to Sentwise AI to continue."
        )
    }

    func testConnectStepHintClearsOnceThatStepIsConnected() {
        let (appState, _) = makeAccountOnly()

        // Account connected → no hint on that step, but the provider still gates.
        XCTAssertNil(appState.onboardingContinueBlockedReason(for: .connectAccount))
        XCTAssertEqual(
            appState.onboardingContinueBlockedReason(for: .connectProvider),
            "Sign in to Sentwise AI to continue."
        )
    }

    func testBYOProviderStepStillPointsAtTestConnection() {
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                llmProvider: "anthropic"
            )
        )
        let appState = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )

        XCTAssertEqual(
            appState.onboardingContinueBlockedReason(for: .connectProvider),
            "Run Test Connection to continue."
        )
    }

    func testNonConnectStepsNeverShowAContinueHint() {
        let (appState, _) = makeDisconnected()

        XCTAssertNil(appState.onboardingContinueBlockedReason(for: .sendBehavior))
        XCTAssertNil(appState.onboardingContinueBlockedReason(for: .voice))
    }

    // MARK: - Reconcile (already-configured install)

    func testReconcileMarksLegacyConfiguredInstallCompleteAndSkipsFlow() {
        // Parked 2026-09-16 (item 100): managed inference is the only shipped path, so
        // a legacy pre-onboarding-flag install counts as "configured" when the account
        // and the managed account are connected. (A legacy BYO selection would fall
        // back to managed on this launch and correctly need sign-in — see
        // testReconcileSendsLegacyBYOInstallThroughOnboarding.)
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .managedClientToken: "client-token",
            .managedSessionID: "session-id"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.onboardingCompletionSchemaVersion - 1,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "managed",
                managedAccountEmail: "me@gmail.com",
                onboardingCompleted: false
            )
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )

        let needsOnboarding = appState.reconcileOnboardingState()

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertFalse(needsOnboarding)
        XCTAssertTrue(appState.onboardingCompleted)
        XCTAssertTrue(persistence.loadSettings().onboardingCompleted,
                      "reconcile must persist the completion so it survives relaunch")
    }

    func testReconcileSendsLegacyBYOInstallThroughOnboarding() {
        // Parked 2026-09-16 (item 100): a legacy install that had selected a BYO
        // provider falls back to managed on launch and, being unsigned, must run the
        // sign-in onboarding rather than being auto-completed.
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: connectedSettings(
                schemaVersion: Settings.onboardingCompletionSchemaVersion - 1,
                onboardingCompleted: false
            )
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )

        XCTAssertEqual(appState.llmProviderKind, .managed)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertTrue(appState.reconcileOnboardingState())
    }

    func testReconcilePreservesPartiallyCompletedCurrentOnboarding() {
        let (appState, persistence) = makeFullyConnected(onboardingCompleted: false)

        let needsOnboarding = appState.reconcileOnboardingState()

        XCTAssertTrue(needsOnboarding)
        XCTAssertFalse(appState.onboardingCompleted)
        XCTAssertFalse(persistence.loadSettings().onboardingCompleted)
        XCTAssertEqual(appState.onboardingResumeStep, .sendBehavior)
    }

    func testReconcileKeepsFlowForFreshInstall() {
        let (appState, persistence) = makeDisconnected(onboardingCompleted: false)

        let needsOnboarding = appState.reconcileOnboardingState()

        XCTAssertTrue(needsOnboarding)
        XCTAssertFalse(appState.onboardingCompleted)
        XCTAssertFalse(persistence.loadSettings().onboardingCompleted)
    }

    func testReconcileLeavesCompletedInstallAlone() {
        let (appState, _) = makeDisconnected(onboardingCompleted: true)
        XCTAssertTrue(appState.onboardingCompleted)
        XCTAssertFalse(appState.reconcileOnboardingState())
    }

    // MARK: - Completion

    func testCompleteOnboardingPersistsAndStartsWatchingWhenReady() {
        let (appState, persistence) = makeFullyConnected(onboardingCompleted: false)

        appState.completeOnboarding()

        XCTAssertTrue(appState.onboardingCompleted)
        XCTAssertTrue(persistence.loadSettings().onboardingCompleted)
        XCTAssertEqual(appState.watchStatus, .watching,
                       "finishing onboarding flips a ready app into watching")
    }

    func testCompleteOnboardingDoesNotWatchWhenNotConnected() {
        // The skip path can complete onboarding even if prerequisites are unmet;
        // it must still persist the flag but not attempt to watch.
        let (appState, persistence) = makeAccountOnly()

        appState.completeOnboarding()

        XCTAssertTrue(appState.onboardingCompleted)
        XCTAssertTrue(persistence.loadSettings().onboardingCompleted)
        XCTAssertEqual(appState.watchStatus, .idle)
    }

    func testCompleteOnboardingDoesNotRestartPausedWatcherOnFirstCompletion() {
        let (appState, persistence) = makeFullyConnected(onboardingCompleted: false)
        appState.watchStatus = .paused

        appState.completeOnboarding()

        XCTAssertTrue(appState.onboardingCompleted)
        XCTAssertTrue(persistence.loadSettings().onboardingCompleted)
        XCTAssertEqual(appState.watchStatus, .paused)
    }

    func testCompleteOnboardingCancelsPendingDebouncedSettingsSave() async throws {
        let (appState, persistence) = makeFullyConnected(onboardingCompleted: false)
        appState.sendBehavior = .autoSend

        appState.completeOnboarding()
        try await Task.sleep(nanoseconds: 700_000_000)

        let settings = persistence.loadSettings()
        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertEqual(settings.sendBehavior, SendBehavior.autoSend.rawValue)
    }

    func testCompleteOnboardingIsIdempotent() {
        let (appState, _) = makeFullyConnected(onboardingCompleted: false)

        appState.completeOnboarding()
        appState.completeOnboarding()

        XCTAssertTrue(appState.onboardingCompleted)
    }

    func testCompleteOnboardingDoesNotRestartPausedWatcherWhenAlreadyComplete() {
        let (appState, _) = makeFullyConnected(onboardingCompleted: true)
        appState.watchStatus = .paused

        appState.completeOnboarding()

        XCTAssertEqual(appState.watchStatus, .paused)
    }

    func testInitLoadsPersistedOnboardingFlag() {
        let (appState, _) = makeDisconnected(onboardingCompleted: true)
        XCTAssertTrue(appState.onboardingCompleted)
    }
}
