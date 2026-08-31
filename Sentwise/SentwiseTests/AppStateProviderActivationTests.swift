import XCTest
import AppKit
@testable import Sentwise

/// A fake `LLMHTTPTransport` returning a fixed response (OpenRouter exchange).
private final class ActivationFakeJSONTransport: LLMHTTPTransport, @unchecked Sendable {
    private let response: HTTPResponse
    init(_ response: HTTPResponse) { self.response = response }
    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        response
    }
}

/// AppState-level tests for the item 59 active-provider badge logic, OpenRouter
/// one-click provisioning, and Google sign-in end to end.
@MainActor
final class AppStateProviderActivationTests: XCTestCase {

    private let startResponse =
        #"{"response":{"id":"sia_1","first_factor_verification":"#
            + #"{"external_verification_redirect_url":"https://accounts.google.com/o/oauth2/auth?x=1"}}}"#
    private let emailStartResponse =
        #"{"response":{"id":"email_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#
    private let emailPrepareResponse = #"{"response":{"id":"email_1"}}"#

    private func makeAppState(
        provider: String = "managed",
        secrets: SecretStore = InMemorySecretStore(),
        managedAccount: ManagedAccountService? = nil
    ) -> AppState {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: provider
        ))
        return AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            managedAccount: managedAccount
        )
    }

    // MARK: - Active-provider badge logic

    func testActiveProviderFlagsAreMutuallyExclusive() {
        let appState = makeAppState(provider: "managed")
        XCTAssertTrue(appState.isManagedProviderActive)
        XCTAssertFalse(appState.isBYOProviderActive)

        appState.selectLLMProvider(.anthropic)
        XCTAssertFalse(appState.isManagedProviderActive)
        XCTAssertTrue(appState.isBYOProviderActive)
    }

    // MARK: - OpenRouter one-click

    func testBeginOpenRouterProvisioningStoresVerifierAndBuildsURL() throws {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)

        let url = try XCTUnwrap(appState.beginOpenRouterProvisioning())
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "callback_url" }?.value, AppState.openRouterCallbackURL)
        XCTAssertTrue(AppState.openRouterCallbackURL.hasSuffix("/openrouter/callback"))
        XCTAssertFalse((items.first { $0.name == "code_challenge" }?.value ?? "").isEmpty)
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")

        let verifier = try secrets.value(for: .openRouterPKCEVerifier)
        XCTAssertFalse((verifier ?? "").isEmpty)
    }

    func testBeginOpenRouterProvisioningDoesNotOverwritePendingVerifier() throws {
        let secrets = InMemorySecretStore(seed: [.openRouterPKCEVerifier: "VER_A"])
        let appState = makeAppState(secrets: secrets)
        XCTAssertTrue(appState.isOpenRouterProvisioning)

        let url = appState.beginOpenRouterProvisioning()

        XCTAssertNil(url)
        XCTAssertEqual(try secrets.value(for: .openRouterPKCEVerifier), "VER_A")
        XCTAssertTrue(appState.isOpenRouterProvisioning)
        XCTAssertNotNil(appState.llmError)
    }

    func testCancelOpenRouterProvisioningClearsPendingVerifier() throws {
        let secrets = InMemorySecretStore(seed: [.openRouterPKCEVerifier: "VER_A"])
        let appState = makeAppState(secrets: secrets)

        appState.cancelOpenRouterProvisioning()

        XCTAssertFalse(appState.isOpenRouterProvisioning)
        XCTAssertNil(try secrets.value(for: .openRouterPKCEVerifier))
        XCTAssertNil(appState.llmError)
    }

    func testHandleOpenRouterCallbackActivatesOpenAICompatibleProvider() async throws {
        let secrets = InMemorySecretStore(seed: [
            .openRouterPKCEVerifier: "VER",
            LLMProviderKind.openAICompatible.apiKeySecret: "sk-openai-existing"
        ])
        let appState = makeAppState(provider: "managed", secrets: secrets)
        let transport = ActivationFakeJSONTransport(
            HTTPResponse(statusCode: 200, body: Data(#"{"key":"sk-or-xyz"}"#.utf8))
        )

        await appState.handleOpenRouterCallback(
            code: "CODE",
            provisioner: OpenRouterKeyProvisioner(transport: transport)
        )

        XCTAssertEqual(appState.llmProviderKind, .openAICompatible)
        XCTAssertEqual(appState.llmBaseURL, OpenRouterKeyProvisioner.apiBaseURL)
        XCTAssertEqual(appState.llmModel, AppState.openRouterDefaultModel)
        XCTAssertFalse(appState.isOpenRouterProvisioning)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertTrue(appState.isBYOProviderActive)
        XCTAssertEqual(try secrets.value(for: .openRouterAPIKey), "sk-or-xyz")
        XCTAssertEqual(try secrets.value(for: LLMProviderKind.openAICompatible.apiKeySecret), "sk-openai-existing")
        XCTAssertEqual(appState.currentDraftLLMConfiguration?.apiKey, "sk-or-xyz")
        XCTAssertNil((try secrets.value(for: .openRouterPKCEVerifier)) ?? nil, "verifier is consumed")
        XCTAssertNil(appState.llmError)
    }

    func testStoredOpenRouterCredentialCanBeReactivatedWithoutOverwritingGenericKey() throws {
        let secrets = InMemorySecretStore(seed: [
            .openRouterAPIKey: "sk-or-existing",
            LLMProviderKind.openAICompatible.apiKeySecret: "sk-openai-existing"
        ])
        let appState = makeAppState(provider: "managed", secrets: secrets)

        appState.selectLLMProvider(.openAICompatible)

        XCTAssertEqual(appState.llmBaseURL, "")
        XCTAssertEqual(appState.llmAPIKey, "sk-openai-existing")
        XCTAssertFalse(appState.isLLMConnected)

        appState.activateStoredOpenRouterProvider()

        XCTAssertEqual(appState.llmProviderKind, .openAICompatible)
        XCTAssertEqual(appState.llmBaseURL, OpenRouterKeyProvisioner.apiBaseURL)
        XCTAssertEqual(appState.llmAPIKey, "sk-or-existing")
        XCTAssertEqual(appState.llmModel, AppState.openRouterDefaultModel)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(appState.currentDraftLLMConfiguration?.apiKey, "sk-or-existing")
        XCTAssertEqual(try secrets.value(for: .openRouterAPIKey), "sk-or-existing")
        XCTAssertEqual(try secrets.value(for: LLMProviderKind.openAICompatible.apiKeySecret), "sk-openai-existing")
        XCTAssertNil(appState.llmError)
    }

    func testHandleOpenRouterCallbackPreservesVerifierWhenAPIKeySaveFails() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .openRouterPKCEVerifier: "VER",
            LLMProviderKind.openAICompatible.apiKeySecret: "sk-openai-existing"
        ])
        secrets.failOnSetKeys = [.openRouterAPIKey]
        let appState = makeAppState(provider: "managed", secrets: secrets)
        let transport = ActivationFakeJSONTransport(
            HTTPResponse(statusCode: 200, body: Data(#"{"key":"sk-or-xyz"}"#.utf8))
        )

        await appState.handleOpenRouterCallback(
            code: "CODE",
            provisioner: OpenRouterKeyProvisioner(transport: transport)
        )

        XCTAssertEqual(appState.llmProviderKind, .managed)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertFalse(appState.isOpenRouterProvisioning)
        XCTAssertNotNil(appState.llmError)
        XCTAssertEqual(try secrets.value(for: .openRouterPKCEVerifier), "VER")
        XCTAssertNil((try secrets.value(for: .openRouterAPIKey)) ?? nil)
        XCTAssertEqual(try secrets.value(for: LLMProviderKind.openAICompatible.apiKeySecret), "sk-openai-existing")
    }

    func testHandleOpenRouterCallbackWithoutVerifierSetsError() async {
        let appState = makeAppState(provider: "managed")

        await appState.handleOpenRouterCallback(code: "CODE")

        XCTAssertNotNil(appState.llmError)
        XCTAssertFalse(appState.isOpenRouterProvisioning)
        XCTAssertEqual(appState.llmProviderKind, .managed, "provider is left unchanged on failure")
    }

    func testCancelOpenRouterProvisioningDuringExchangeDiscardsReturnedKey() async throws {
        let secrets = InMemorySecretStore(seed: [.openRouterPKCEVerifier: "VER"])
        let appState = makeAppState(provider: "managed", secrets: secrets)
        let transport = ManagedProviderSuspendedLLMTransport()

        let callback = Task {
            await appState.handleOpenRouterCallback(
                code: "CODE",
                provisioner: OpenRouterKeyProvisioner(transport: transport)
            )
        }
        await fulfillment(of: [transport.didStartRequest], timeout: 1)

        appState.cancelOpenRouterProvisioning()
        transport.complete(with: .success(HTTPResponse(
            statusCode: 200,
            body: Data(#"{"key":"sk-or-cancelled"}"#.utf8)
        )))
        await callback.value

        XCTAssertEqual(appState.llmProviderKind, .managed)
        XCTAssertFalse(appState.isOpenRouterProvisioning)
        XCTAssertFalse(appState.isTestingLLM)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertNil((try secrets.value(for: .openRouterAPIKey)) ?? nil)
        XCTAssertNil((try secrets.value(for: .openRouterPKCEVerifier)) ?? nil)
        XCTAssertNil(appState.llmError)
    }

    func testLegacyOpenRouterKeyMigratesToDedicatedSecretOnInit() {
        let secrets = InMemorySecretStore(seed: [
            .llmAPIKey(provider: "openAICompatible"): "sk-legacy-openrouter"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "openAICompatible",
            llmModel: "gpt-4o-mini",
            llmBaseURL: "https://openrouter.ai/api/v1",
            llmVerifiedModel: "gpt-4o-mini"
        ))

        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )

        XCTAssertEqual(appState.llmProviderKind, .openAICompatible)
        XCTAssertEqual(appState.llmBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(appState.llmAPIKey, "sk-legacy-openrouter")
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(try? secrets.value(for: .openRouterAPIKey), "sk-legacy-openrouter")
        XCTAssertNil((try? secrets.value(for: .llmAPIKey(provider: "openAICompatible"))) ?? nil)
        XCTAssertEqual(appState.currentDraftLLMConfiguration?.apiKey, "sk-legacy-openrouter")
    }

    // MARK: - URL routing / hunt-mode guard

    func testIncomingCallbackIgnoredDuringHunt() {
        let appState = makeAppState()
        let url = URL(string: "sentwise://openrouter-callback?code=CODE")!

        XCTAssertNil(appState.routableCallback(for: url, isHuntMode: true),
                     "a hunt must never reach the completion paths, even via a stray deep link")
        XCTAssertEqual(appState.routableCallback(for: url, isHuntMode: false), .openRouter(code: "CODE"))
        XCTAssertNil(appState.routableCallback(for: URL(string: "https://evil?code=x")!, isHuntMode: false))
    }

    // MARK: - Google sign-in end to end

    func testGoogleSignInEndToEndSignsInAndActivatesManaged() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(startResponse, clientToken: "client_A"),
            clerkReply(
                #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1","identifier":"marcus@example.com"}}"#,
                clientToken: "client_B"
            ),
            clerkReply(#"{"jwt":"jwt.value"}"#, clientToken: "client_C")
        ])
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        let managed = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = makeAppState(provider: "anthropic", secrets: secrets, managedAccount: managed)

        var opened: URL?
        await appState.startManagedGoogleSignIn { opened = $0 }
        XCTAssertEqual(opened?.absoluteString, "https://accounts.google.com/o/oauth2/auth?x=1")
        XCTAssertEqual(appState.managedSignInStage, .awaitingBrowser,
                       "opening the browser should switch the panel to the waiting state")

        await appState.handleManagedOAuthCallback(nonce: "nonce_1")

        XCTAssertEqual(appState.managedSignInStage, .idle, "a completed sign-in leaves the waiting state")
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isManagedProviderActive)
        XCTAssertEqual(appState.managedAccountEmail, "marcus@example.com")
        XCTAssertNil(appState.managedError)
    }

    func testEmailCodeSignInActivatesManagedFromBYOProvider() async throws {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-anthropic"])
        let transport = QueueClerkTransport([
            clerkReply(emailStartResponse, clientToken: "client_A"),
            clerkReply(emailPrepareResponse, clientToken: "client_B"),
            clerkReply(#"{"response":{"id":"email_1","status":"complete","created_session_id":"sess_1"}}"#,
                       clientToken: "client_C"),
            clerkReply(#"{"jwt":"jwt.value"}"#, clientToken: "client_D")
        ])
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        let managed = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = makeAppState(provider: "anthropic", secrets: secrets, managedAccount: managed)

        appState.managedEmailInput = "marcus@example.com"
        await appState.startManagedSignIn()
        appState.managedCodeInput = "123456"
        await appState.verifyManagedCode()

        XCTAssertEqual(appState.llmProviderKind, .managed)
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isManagedProviderActive)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(appState.verifiedLLMModel, LLMProviderKind.managed.defaultModel)
        XCTAssertEqual(appState.managedAccountEmail, "marcus@example.com")
        XCTAssertNil(appState.managedError)
    }

    func testNotificationOnlyEmailSignInPreservesBYOProvider() async {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-anthropic"])
        let appState = makeAppState(provider: "anthropic", secrets: secrets)

        appState.managedEmailInput = "marcus@example.com"
        await appState.startManagedSignIn(isHuntMode: true)
        appState.managedCodeInput = "123456"
        await appState.verifyManagedCode(activatesManagedProvider: false, isHuntMode: true)

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertEqual(appState.managedAccountEmail, "marcus@example.com")
        XCTAssertEqual(appState.llmProviderKind, .anthropic)
        XCTAssertFalse(appState.isManagedProviderActive)
    }

    func testCancelManagedGoogleSignInIgnoresLaterCallback() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([clerkReply(startResponse, clientToken: "client_A")])
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        let managed = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = makeAppState(provider: "managed", secrets: secrets, managedAccount: managed)

        await appState.startManagedGoogleSignIn { _ in }
        XCTAssertEqual(appState.managedSignInStage, .awaitingBrowser)

        await appState.cancelManagedSignInFlow()
        await appState.handleManagedOAuthCallback(nonce: "nonce_1")

        XCTAssertEqual(appState.managedSignInStage, .idle)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertNotNil(appState.managedError)
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testStaleManagedOAuthCallbackDoesNotClearEmailCodeStage() async {
        let appState = makeAppState(provider: "managed")
        appState.managedEmailInput = "marcus@example.com"
        await appState.startManagedSignIn(isHuntMode: true)
        XCTAssertEqual(appState.managedSignInStage, .codeSent)

        await appState.handleManagedOAuthCallback(nonce: "stale_nonce")

        XCTAssertEqual(appState.managedSignInStage, .codeSent)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertNotNil(appState.managedError)
    }

    func testAppDelegateQueuesIncomingURLsUntilLaunchInitializesAppState() {
        let delegate = AppDelegate(runtime: ProwlHuntRuntime(isEnabled: true))
        let url = URL(string: "sentwise://openrouter-callback?code=CODE")!

        delegate.application(NSApplication.shared, open: [url])
        XCTAssertEqual(delegate.pendingIncomingURLCount, 1)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(delegate.pendingIncomingURLCount, 0)
    }
}
