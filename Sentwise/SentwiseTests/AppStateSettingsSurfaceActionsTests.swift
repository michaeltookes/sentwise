import XCTest
@testable import Sentwise

@MainActor
final class AppStateSettingsSurfaceActionsTests: XCTestCase {

    private func makeAppState(
        persistence: AppStateMemoryPersistence = AppStateMemoryPersistence(),
        secrets: SecretStore = InMemorySecretStore()
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    func testForgetVoiceProfileClearsSettingsVoiceErrorBucket() {
        let profile = VoiceProfile(
            greeting: "Hey,",
            signOff: "M",
            formality: "casual",
            tone: "warm",
            averageLength: "short",
            commonPhrases: [],
            summary: "Loaded.",
            sampleCount: 3,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let persistence = AppStateMemoryPersistence(settings: .default, voiceProfile: profile)
        let appState = makeAppState(persistence: persistence)
        appState.voiceProfile = profile
        appState.voiceError = "setup assistant error"
        appState.settingsTransientMessages.voiceError = "settings error"

        appState.forgetVoiceProfile(messageSurface: .settings)

        XCTAssertNil(appState.voiceProfile)
        XCTAssertNil(persistence.voiceProfile)
        XCTAssertEqual(appState.voiceError, "setup assistant error")
        XCTAssertNil(appState.voiceError(for: .settings))
    }

    func testManagedSignOutClearsSettingsOAuthInterestErrorBucket() async {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com",
            managedAccountID: "acct-1"
        ))
        let appState = makeAppState(persistence: persistence, secrets: secrets)
        appState.googleOAuthInterestRegistered = true
        appState.googleOAuthInterestError = "setup assistant interest error"
        appState.settingsTransientMessages.googleOAuthInterestError = "settings interest error"

        await appState.signOutManaged(messageSurface: .settings)

        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.googleOAuthInterestRegistered)
        XCTAssertEqual(appState.googleOAuthInterestError, "setup assistant interest error")
        XCTAssertNil(appState.googleOAuthInterestError(for: .settings))
    }

    func testManagedInputEditsClearOnlyRequestedSurface() {
        let appState = makeAppState()
        appState.managedError = "setup assistant email error"
        appState.settingsTransientMessages.managedError = "settings email error"

        appState.updateManagedEmailInputFromUser("marcus@example.com", messageSurface: .settings)

        XCTAssertEqual(appState.managedEmailInput, "marcus@example.com")
        XCTAssertEqual(appState.managedError, "setup assistant email error")
        XCTAssertNil(appState.managedError(for: .settings))

        appState.managedError = "setup assistant code error"
        appState.settingsTransientMessages.managedError = "settings code error"

        appState.updateManagedCodeInputFromUser("123456", messageSurface: .shared)

        XCTAssertEqual(appState.managedCodeInput, "123456")
        XCTAssertNil(appState.managedError)
        XCTAssertEqual(appState.managedError(for: .settings), "settings code error")
    }

    func testSettingsConnectionErrorFallsBackToAppWideMailboxError() {
        let appState = makeAppState()
        appState.setAppWideConnectionError("startup mailbox error")

        XCTAssertEqual(appState.connectionError(for: .settings), "startup mailbox error")

        appState.settingsTransientMessages.connectionError = "settings mailbox error"

        XCTAssertEqual(appState.connectionError(for: .settings), "settings mailbox error")
    }

    func testSettingsConnectionErrorDoesNotFallBackToSharedSurfaceError() {
        let appState = makeAppState()

        appState.setConnectionError("setup assistant mailbox error", for: .shared)

        XCTAssertEqual(appState.connectionError, "setup assistant mailbox error")
        XCTAssertNil(appState.connectionError(for: .settings))
    }
}
