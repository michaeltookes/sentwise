import XCTest
@testable import Sentwise

/// Launch-time behavior of the managed-inference provider (item 56a): the
/// fresh-install default and restoring the verified state from stored credentials.
@MainActor
final class AppStateManagedLaunchTests: XCTestCase {
    private func makeAppState(
        secrets: SecretStore = InMemorySecretStore(),
        persistence: AppStateMemoryPersistence = AppStateMemoryPersistence(),
        llm: LLMProviding = FakeLLMProvider(result: .success(()))
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm
        )
    }

    func testDefaultLLMStateIsManagedForFreshInstall() {
        // Managed inference is the default for new installs (item 56a). Not signed
        // in yet, so it is disconnected; the model is the managed default.
        let appState = makeAppState()

        XCTAssertEqual(appState.llmProviderKind, .managed)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.resolvedLLMModel, "claude-sonnet-4-6")
    }

    func testManagedCredentialsRestoreDefaultVerificationOnLaunch() {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmModel: "stale-custom-model",
            llmVerifiedModel: "",
            managedAccountEmail: "marcus@example.com"
        ))

        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertEqual(appState.llmProviderKind, .managed)
        XCTAssertEqual(appState.llmModel, "")
        XCTAssertEqual(appState.verifiedLLMModel, LLMProviderKind.managed.defaultModel)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(
            try? secrets.value(for: .managedClerkFrontendAPIBaseURL),
            ClerkClient.defaultFrontendAPIBaseURLString
        )
        let saved = persistence.loadSettings()
        XCTAssertEqual(saved.llmModel, "")
        XCTAssertEqual(saved.llmVerifiedModel, LLMProviderKind.managed.defaultModel)
    }

    func testPreCutoverManagedCredentialsDoNotRestoreAfterProductionClerkMigration() throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "dev-client",
            .managedSessionID: "dev-session"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.clerkProductionCutoverSchemaVersion - 1,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com",
            managedAccountID: "clerk-user:user_dev"
        ))

        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountEmail, "")
        XCTAssertEqual(appState.managedAccountID, "")
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
        let saved = persistence.loadSettings()
        XCTAssertEqual(saved.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(saved.managedAccountEmail, "")
        XCTAssertEqual(saved.managedAccountID, "")
    }

    func testUnmarkedCurrentSchemaManagedCredentialsAreClearedWhenSettingsIdentityIsMissing() throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "dev-client",
            .managedSessionID: "dev-session"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel
        ))

        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
        XCTAssertEqual(
            try secrets.value(for: .managedClerkFrontendAPIBaseURL),
            ClerkClient.defaultFrontendAPIBaseURLString
        )
    }

    func testUnmarkedCurrentSchemaPartialManagedCredentialsAreClearedWhenSettingsIdentityIsMissing() throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "dev-client",
            .managedOAuthSignInID: "sia_1",
            .managedOAuthFlowID: "flow_1",
            .managedOAuthMessageSurface: "settings"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel
        ))

        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedOAuthSignInID))
        XCTAssertNil(try secrets.value(for: .managedOAuthFlowID))
        XCTAssertNil(try secrets.value(for: .managedOAuthMessageSurface))
        XCTAssertEqual(
            try secrets.value(for: .managedClerkFrontendAPIBaseURL),
            ClerkClient.defaultFrontendAPIBaseURLString
        )
    }

    func testMarkedCurrentSchemaPendingOAuthStateSurvivesWhenSessionIsMissing() throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_A",
            .managedOAuthSignInID: "sia_1",
            .managedOAuthFlowID: "flow_1",
            .managedOAuthMessageSurface: "settings",
            .managedClerkFrontendAPIBaseURL: ClerkClient.defaultFrontendAPIBaseURLString
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel
        ))

        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_A")
        XCTAssertEqual(try secrets.value(for: .managedOAuthSignInID), "sia_1")
        XCTAssertEqual(try secrets.value(for: .managedOAuthFlowID), "flow_1")
        XCTAssertEqual(try secrets.value(for: .managedOAuthMessageSurface), "settings")
        XCTAssertEqual(
            try secrets.value(for: .managedClerkFrontendAPIBaseURL),
            ClerkClient.defaultFrontendAPIBaseURLString
        )
    }
}
