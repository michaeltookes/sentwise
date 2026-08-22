import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateLLMTests: XCTestCase {

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

    func testResolvedModelUsesCustomModelWhenSet() {
        let appState = makeAppState()
        appState.llmModel = "  claude-haiku-4-5-20251001  "

        XCTAssertEqual(appState.resolvedLLMModel, "claude-haiku-4-5-20251001")
    }

    func testTestLLMConnectionSuccessStoresKeyAndConnects() async {
        let secrets = InMemorySecretStore()
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.selectLLMProvider(.anthropic)
        appState.llmAPIKey = "  sk-live  "

        await appState.testLLMConnection()

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertNil(appState.llmError)
        XCTAssertFalse(appState.isTestingLLM)
        XCTAssertEqual(tester.lastAPIKey, "sk-live", "key must be trimmed before use")
        XCTAssertEqual(tester.lastModel, "claude-sonnet-4-6")
        XCTAssertEqual(appState.verifiedLLMModel, "claude-sonnet-4-6")
        XCTAssertEqual(try? secrets.value(for: .llmAPIKey(provider: "anthropic")), "sk-live")
    }

    func testTestLLMConnectionFailureDoesNotStoreKey() async {
        let secrets = InMemorySecretStore()
        let tester = FakeLLMProvider(result: .failure(.http(status: 401, message: "bad key")))
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.selectLLMProvider(.anthropic)
        appState.llmAPIKey = "sk-wrong"

        await appState.testLLMConnection()

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertNotNil(appState.llmError)
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "anthropic"))) ?? nil)
    }

    func testTestLLMConnectionRequiresRetestWhenModelChangesDuringRequest() async {
        let secrets = InMemorySecretStore()
        let tester = SuspendedLLMConnectionTester()
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.selectLLMProvider(.anthropic)
        appState.llmAPIKey = "sk-live"
        appState.llmModel = "claude-sonnet-4-6"

        let connectionTask = Task { await appState.testLLMConnection() }
        await fulfillment(of: [tester.didStartConnectionTest], timeout: 1)

        appState.llmModel = "claude-sonnet-5"
        tester.complete(with: .success(()))
        await connectionTask.value

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertFalse(appState.isTestingLLM)
        XCTAssertEqual(appState.llmError, "Connection settings changed. Test again.")
        XCTAssertEqual(appState.verifiedLLMModel, "")
        XCTAssertEqual(tester.lastModel, "claude-sonnet-4-6")
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "anthropic"))) ?? nil)
    }

    func testTestLLMConnectionRequiresRetestWhenKeyChangesDuringRequest() async {
        let secrets = InMemorySecretStore()
        let tester = SuspendedLLMConnectionTester()
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.selectLLMProvider(.anthropic)
        appState.llmAPIKey = "sk-live"

        let connectionTask = Task { await appState.testLLMConnection() }
        await fulfillment(of: [tester.didStartConnectionTest], timeout: 1)

        appState.llmAPIKey = "sk-edited"
        tester.complete(with: .success(()))
        await connectionTask.value

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertFalse(appState.isTestingLLM)
        XCTAssertEqual(appState.llmError, "Connection settings changed. Test again.")
        XCTAssertEqual(appState.verifiedLLMModel, "")
        XCTAssertEqual(tester.lastAPIKey, "sk-live")
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "anthropic"))) ?? nil)
    }

    func testTestLLMConnectionRequiresKey() async {
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(llm: tester)
        appState.selectLLMProvider(.anthropic)
        appState.llmAPIKey = "   "

        await appState.testLLMConnection()

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertNotNil(appState.llmError)
        XCTAssertNil(tester.lastAPIKey, "tester must not be called without a key")
    }

    func testDisconnectLLMClearsStoredKey() async {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        appState.selectLLMProvider(.anthropic)
        appState.llmAPIKey = "sk-live"
        await appState.testLLMConnection()

        appState.disconnectLLM()

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.llmAPIKey, "")
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "anthropic"))) ?? nil)
    }

    func testLLMKeyAndModelRestoredOnInit() {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-stored"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "anthropic",
            llmModel: "claude-opus-4-8",
            llmVerifiedModel: "claude-opus-4-8"
        ))
        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(appState.llmAPIKey, "sk-stored")
        XCTAssertEqual(appState.llmModel, "claude-opus-4-8")
        XCTAssertEqual(appState.resolvedLLMModel, "claude-opus-4-8")
    }

    func testLLMKeyWithoutVerifiedModelRestoresDisconnected() {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-stored"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "anthropic",
            llmModel: "claude-opus-4-8"
        ))
        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.llmAPIKey, "sk-stored")
    }

    // MARK: - OpenAI-compatible provider + custom base URL (item 6)

    func testSelectingOpenAICompatibleProviderUpdatesDefaultModel() {
        let appState = makeAppState()

        appState.selectLLMProvider(.openAICompatible)

        XCTAssertEqual(appState.llmProviderKind, .openAICompatible)
        XCTAssertEqual(appState.llmModel, "")
        XCTAssertEqual(appState.resolvedLLMModel, "gpt-4o-mini")
        XCTAssertTrue(appState.llmProviderKind.supportsCustomBaseURL)
        XCTAssertFalse(appState.isLLMConnected)
    }

    func testSelectingProviderClearsCustomModelForNewProviderDefault() {
        let appState = makeAppState()
        appState.llmModel = "claude-opus-4-8"

        appState.selectLLMProvider(.openAICompatible)

        XCTAssertEqual(appState.llmModel, "")
        XCTAssertEqual(appState.resolvedLLMModel, "gpt-4o-mini")

        appState.llmModel = "openrouter/custom-model"
        appState.selectLLMProvider(.anthropic)

        XCTAssertEqual(appState.llmModel, "")
        XCTAssertEqual(appState.resolvedLLMModel, "claude-sonnet-4-6")
    }

    func testSelectingProviderClearsSharedCustomBaseURL() {
        let appState = makeAppState()
        appState.selectLLMProvider(.openAICompatible)
        appState.llmBaseURL = "https://openrouter.ai/api/v1"

        appState.selectLLMProvider(.ollama)

        XCTAssertEqual(appState.llmProviderKind, .ollama)
        XCTAssertEqual(appState.llmBaseURL, "")
        XCTAssertNil(appState.currentLLMBaseURL)
    }

    func testSelectingLocalAfterCustomEndpointUsesProviderDefaultEndpoint() async {
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(llm: tester)
        appState.selectLLMProvider(.openAICompatible)
        appState.llmBaseURL = "https://openrouter.ai/api/v1"

        appState.selectLLMProvider(.ollama)
        await appState.testLLMConnection()

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(tester.lastProvider, .ollama)
        XCTAssertNil(tester.lastBaseURL)
    }

    func testTestConnectionPassesCustomBaseURLForOpenAICompatible() async {
        let secrets = InMemorySecretStore()
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.selectLLMProvider(.openAICompatible)
        appState.llmBaseURL = "https://openrouter.ai/api/v1"
        appState.llmAPIKey = "sk-gateway"

        await appState.testLLMConnection()

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(tester.lastProvider, .openAICompatible)
        XCTAssertEqual(tester.lastBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(tester.lastModel, "gpt-4o-mini")
        XCTAssertEqual(try? secrets.value(for: .openRouterAPIKey), "sk-gateway")
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "openAICompatible"))) ?? nil)
    }

    func testCurrentBaseURLIsNilForProvidersWithoutEndpointOverride() async {
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(llm: tester)
        appState.selectLLMProvider(.anthropic)
        // Anthropic does not support a custom endpoint; a stray field value is ignored.
        appState.llmBaseURL = "https://example.com/v1"
        appState.llmAPIKey = "sk-live"

        XCTAssertNil(appState.currentLLMBaseURL)

        await appState.testLLMConnection()

        XCTAssertEqual(tester.lastProvider, .anthropic)
        XCTAssertNil(tester.lastBaseURL)
    }

    func testInvalidBaseURLMapsToFriendlyMessage() {
        let message = AppState.llmMessage(for: LLMError.invalidBaseURL("openrouter.ai/api/v1"))

        XCTAssertTrue(message.contains("Invalid base URL"), "message should name the problem: \(message)")
        XCTAssertTrue(message.contains("openrouter.ai/api/v1"), "message should echo the value: \(message)")
    }

    func testTestConnectionWithInvalidBaseURLSurfacesErrorAndStaysDisconnected() async {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets, llm: LLMService(transport: FakeLLMTransport(
            response: HTTPResponse(statusCode: 200, body: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
        )))
        appState.selectLLMProvider(.openAICompatible)
        appState.llmBaseURL = "https://my host/v1"
        appState.llmAPIKey = "sk-gateway"

        await appState.testLLMConnection()

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.llmError, "Invalid base URL: https://my host/v1. Enter a full http(s) URL, e.g. https://api.openai.com/v1.")
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "openAICompatible"))) ?? nil)
    }

    func testEditingBaseURLRequiresRetest() async {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        appState.selectLLMProvider(.openAICompatible)
        appState.llmBaseURL = "https://openrouter.ai/api/v1"
        appState.llmAPIKey = "sk-gateway"
        await appState.testLLMConnection()
        XCTAssertTrue(appState.isLLMConnected)

        appState.updateLLMBaseURLFromUser("https://api.groq.com/openai/v1")

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.verifiedLLMModel, "")
        XCTAssertEqual(appState.llmAPIKey, "")
        XCTAssertNil((try? secrets.value(for: .openRouterAPIKey)) ?? nil)
    }

    func testEditingBaseURLOnSameEndpointOriginKeepsKeyButRequiresRetest() async {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        appState.selectLLMProvider(.openAICompatible)
        appState.llmBaseURL = "https://openrouter.ai/api/v1"
        appState.llmAPIKey = "sk-gateway"
        await appState.testLLMConnection()
        XCTAssertTrue(appState.isLLMConnected)

        appState.updateLLMBaseURLFromUser("https://openrouter.ai/api/v1/")

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.verifiedLLMModel, "")
        XCTAssertEqual(appState.llmAPIKey, "sk-gateway")
        XCTAssertEqual(try? secrets.value(for: .openRouterAPIKey), "sk-gateway")
    }

    func testOpenAICompatibleBaseURLRestoredOnInit() {
        let secrets = InMemorySecretStore(seed: [.openRouterAPIKey: "sk-stored"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "openAICompatible",
            llmModel: "gpt-4o-mini",
            llmBaseURL: "https://openrouter.ai/api/v1",
            llmVerifiedModel: "gpt-4o-mini"
        ))
        let appState = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertEqual(appState.llmProviderKind, .openAICompatible)
        XCTAssertEqual(appState.llmBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(appState.currentLLMBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(appState.llmAPIKey, "sk-stored")
        XCTAssertTrue(appState.isLLMConnected)
    }

    func testSelectingOpenAICompatibleRestoresStoredOpenRouterCredential() {
        let secrets = InMemorySecretStore(seed: [.openRouterAPIKey: "sk-openrouter"])
        let appState = makeAppState(secrets: secrets)

        appState.selectLLMProvider(.openAICompatible)

        XCTAssertEqual(appState.llmProviderKind, .openAICompatible)
        XCTAssertEqual(appState.llmBaseURL, OpenRouterKeyProvisioner.apiBaseURL)
        XCTAssertEqual(appState.currentLLMBaseURL, OpenRouterKeyProvisioner.apiBaseURL)
        XCTAssertEqual(appState.llmAPIKey, "sk-openrouter")
        XCTAssertEqual(appState.llmModel, AppState.openRouterDefaultModel)
        XCTAssertEqual(appState.verifiedLLMModel, AppState.openRouterDefaultModel)
        XCTAssertTrue(appState.isLLMConnected)
    }

    // MARK: - Local (Ollama) key-optional provider (item 16)

    func testSelectingLocalProviderUpdatesDefaultsAndIsKeyOptional() {
        let appState = makeAppState()

        appState.selectLLMProvider(.ollama)

        XCTAssertEqual(appState.llmProviderKind, .ollama)
        XCTAssertEqual(appState.llmModel, "")
        XCTAssertEqual(appState.resolvedLLMModel, "llama3.1")
        XCTAssertTrue(appState.llmProviderKind.supportsCustomBaseURL)
        XCTAssertFalse(appState.llmProviderKind.requiresAPIKey)
        XCTAssertFalse(appState.isLLMConnected)
    }

    func testTestConnectionForLocalProviderConnectsWithoutKeyAndStoresNothing() async {
        let secrets = InMemorySecretStore()
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.selectLLMProvider(.ollama)
        // No API key entered.

        await appState.testLLMConnection()

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertNil(appState.llmError)
        XCTAssertEqual(tester.lastProvider, .ollama)
        XCTAssertEqual(tester.lastAPIKey, "", "an empty key is passed through for local providers")
        XCTAssertEqual(tester.lastModel, "llama3.1")
        XCTAssertEqual(appState.verifiedLLMModel, "llama3.1")
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "ollama"))) ?? nil,
                     "no empty key should be written to the Keychain")
    }

    func testTestConnectionForLocalProviderStoresOptionalKey() async {
        let secrets = InMemorySecretStore()
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.selectLLMProvider(.ollama)
        appState.llmAPIKey = "  sk-local-proxy  "

        await appState.testLLMConnection()

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertNil(appState.llmError)
        XCTAssertEqual(tester.lastProvider, .ollama)
        XCTAssertEqual(tester.lastAPIKey, "sk-local-proxy")
        XCTAssertEqual(try? secrets.value(for: .llmAPIKey(provider: "ollama")), "sk-local-proxy")
    }

    func testTestConnectionForLocalProviderClearsStoredOptionalKeyWhenBlank() async {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "ollama"): "sk-old-local"])
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.selectLLMProvider(.ollama)
        appState.llmAPIKey = "   "

        await appState.testLLMConnection()

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertNil(appState.llmError)
        XCTAssertEqual(tester.lastAPIKey, "")
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "ollama"))) ?? nil)
    }

    func testConnectedLocalProviderStaysConnectedAfterStatusRefresh() async {
        let appState = makeAppState()
        appState.selectLLMProvider(.ollama)
        await appState.testLLMConnection()
        XCTAssertTrue(appState.isLLMConnected)

        // A later refresh (e.g. on a benign model-field re-set) must not flip a
        // key-optional provider back to disconnected just because no key exists.
        appState.refreshLLMConnectionStatus()

        XCTAssertTrue(appState.isLLMConnected)
    }

    func testLocalProviderCanGenerateDraftWithoutKey() async {
        let secrets = InMemorySecretStore()
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(secrets: secrets, llm: tester)
        appState.selectLLMProvider(.ollama)
        await appState.testLLMConnection()
        appState.mailEmail = "sam@example.com"
        appState.mailAppPassword = "app-password-here"

        XCTAssertTrue(appState.canGenerateDraft, "a connected local provider should permit drafting without a key")
    }

    func testTestConnectionForLocalProviderPassesCustomBaseURL() async {
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(llm: tester)
        appState.selectLLMProvider(.ollama)
        appState.llmBaseURL = "http://localhost:1234/v1"

        await appState.testLLMConnection()

        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(tester.lastProvider, .ollama)
        XCTAssertEqual(tester.lastBaseURL, "http://localhost:1234/v1")
    }

    func testDisconnectLocalProviderReturnsToDisconnected() async {
        let appState = makeAppState()
        appState.selectLLMProvider(.ollama)
        await appState.testLLMConnection()
        XCTAssertTrue(appState.isLLMConnected)

        appState.disconnectLLM()

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.verifiedLLMModel, "")
    }

    func testLocalProviderRestoresConnectedFromSettingsWithoutKey() {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "ollama",
            llmModel: "llama3.1",
            llmVerifiedModel: "llama3.1"
        ))
        let appState = makeAppState(persistence: persistence)

        XCTAssertEqual(appState.llmProviderKind, .ollama)
        XCTAssertTrue(appState.isLLMConnected, "a previously-verified local provider reconnects with no key")
        XCTAssertEqual(appState.llmAPIKey, "")
    }

    func testChangingConnectedLLMModelRequiresRetest() {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-stored"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "anthropic",
            llmModel: "claude-sonnet-4-6",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let appState = makeAppState(secrets: secrets, persistence: persistence)
        XCTAssertTrue(appState.isLLMConnected)

        appState.llmModel = "claude-sonnet-5"
        appState.saveSettingsSync()

        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.llmAPIKey, "sk-stored")
        let settings = persistence.loadSettings()
        XCTAssertEqual(settings.llmModel, "claude-sonnet-5")
        XCTAssertEqual(settings.llmVerifiedModel, "claude-sonnet-4-6")
    }
}
