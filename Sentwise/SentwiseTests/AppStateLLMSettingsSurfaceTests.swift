import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateLLMSettingsSurfaceTests: XCTestCase {

    private func makeAppState(
        secrets: SecretStore,
        persistence: AppStateMemoryPersistence
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    func testDisconnectLLMFailureUsesSettingsErrorBucket() {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .llmAPIKey(provider: "anthropic"): "sk-stored"
        ])
        secrets.failOnRemoveKeys = [.llmAPIKey(provider: "anthropic")]
        let appState = makeAppState(secrets: secrets, persistence: AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "anthropic",
            llmModel: "claude-sonnet-4-6",
            llmVerifiedModel: "claude-sonnet-4-6"
        )))

        appState.disconnectLLM(messageSurface: .settings)

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertNil(appState.llmError)
        XCTAssertNotNil(appState.llmError(for: .settings))
        XCTAssertEqual(try? secrets.value(for: .llmAPIKey(provider: "anthropic")), "sk-stored")
    }

    func testEditingBaseURLKeyCleanupFailureUsesSettingsErrorBucket() {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .openRouterAPIKey: "sk-openrouter"
        ])
        secrets.failOnRemoveKeys = [.openRouterAPIKey]
        let appState = makeAppState(secrets: secrets, persistence: AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "openAICompatible",
            llmModel: AppState.openRouterDefaultModel,
            llmBaseURL: OpenRouterKeyProvisioner.apiBaseURL,
            llmVerifiedModel: AppState.openRouterDefaultModel
        )))

        appState.updateLLMBaseURLFromUser("https://api.groq.com/openai/v1", messageSurface: .settings)

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertNil(appState.llmError)
        XCTAssertNotNil(appState.llmError(for: .settings))
        XCTAssertEqual(try? secrets.value(for: .openRouterAPIKey), "sk-openrouter")
    }

    func testProviderSelectionClearsSettingsLLMErrorBucket() {
        let appState = makeAppState(secrets: InMemorySecretStore(), persistence: AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed"
        )))
        appState.llmError = "setup assistant error"
        appState.settingsTransientMessages.llmError = "settings error"

        appState.selectLLMProvider(.anthropic, messageSurface: .settings)

        XCTAssertEqual(appState.llmProviderKind, .anthropic)
        XCTAssertEqual(appState.llmError, "setup assistant error")
        XCTAssertNil(appState.llmError(for: .settings))
    }
}
