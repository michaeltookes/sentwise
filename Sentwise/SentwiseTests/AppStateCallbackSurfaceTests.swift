import XCTest
@testable import Sentwise

private final class CallbackSurfaceJSONTransport: LLMHTTPTransport, @unchecked Sendable {
    private let response: HTTPResponse
    private(set) var callCount = 0

    init(_ response: HTTPResponse) {
        self.response = response
    }

    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        callCount += 1
        return response
    }
}

@MainActor
final class AppStateCallbackSurfaceTests: XCTestCase {

    private let startResponse =
        #"{"response":{"id":"sia_1","first_factor_verification":"#
            + #"{"external_verification_redirect_url":"https://accounts.google.com/o/oauth2/auth?x=1"}}}"#

    private func callbackState(from urlString: String?) -> String? {
        guard let urlString else { return nil }
        return URLComponents(string: urlString)?.queryItems?.first { $0.name == "state" }?.value
    }

    private func openRouterCallbackState(from authURL: URL) -> String? {
        let items = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return callbackState(from: items.first { $0.name == "callback_url" }?.value)
    }

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

    func testRelaunchedOpenRouterCallbackFailureUsesPersistedSettingsSurface() async throws {
        let secrets = InMemorySecretStore()
        let firstLaunch = makeAppState(secrets: secrets)
        let url = try XCTUnwrap(firstLaunch.beginOpenRouterProvisioning(messageSurface: .settings))
        let flowID = try XCTUnwrap(openRouterCallbackState(from: url))
        let relaunched = makeAppState(secrets: secrets)
        let transport = CallbackSurfaceJSONTransport(
            HTTPResponse(statusCode: 500, body: Data(#"{"error":"bad code"}"#.utf8))
        )

        await relaunched.handleOpenRouterCallback(
            code: "CODE",
            flowID: flowID,
            provisioner: OpenRouterKeyProvisioner(transport: transport)
        )

        XCTAssertFalse(relaunched.isOpenRouterProvisioning)
        XCTAssertNil(relaunched.llmError)
        XCTAssertNotNil(relaunched.llmError(for: .settings))
    }

    func testOpenRouterCallbackFailureSurvivesSettingsCloseDuringExchange() async throws {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        let url = try XCTUnwrap(appState.beginOpenRouterProvisioning(messageSurface: .settings))
        let flowID = try XCTUnwrap(openRouterCallbackState(from: url))
        let transport = ManagedProviderSuspendedLLMTransport()
        let callback = Task {
            await appState.handleOpenRouterCallback(
                code: "CODE",
                flowID: flowID,
                provisioner: OpenRouterKeyProvisioner(transport: transport)
            )
        }
        await fulfillment(of: [transport.didStartRequest], timeout: 1)

        appState.resetTransientSettingsMessages()
        transport.complete(with: .success(HTTPResponse(statusCode: 500, body: Data(#"{"error":"bad code"}"#.utf8))))
        await callback.value

        XCTAssertNil(appState.llmError)
        XCTAssertNotNil(appState.llmError(for: .settings))

        appState.resetTransientSettingsMessages()

        XCTAssertNotNil(appState.llmError(for: .settings))
    }

    func testCanceledSettingsOpenRouterCallbackIsIgnored() async throws {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        appState.llmError = "setup assistant error"
        _ = try XCTUnwrap(appState.beginOpenRouterProvisioning(messageSurface: .settings))

        appState.cancelOpenRouterProvisioning(messageSurface: .settings)
        await appState.handleOpenRouterCallback(code: "CODE")

        XCTAssertEqual(appState.llmError, "setup assistant error")
        XCTAssertNil(appState.llmError(for: .settings))
        XCTAssertNil((try secrets.value(for: .openRouterPKCEVerifier)) ?? nil)
        XCTAssertNil((try secrets.value(for: .openRouterCanceledCallbackSurface)) ?? nil)
    }

    func testCanceledSettingsOpenRouterCallbackDoesNotDisturbReplacementFlow() async throws {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        let urlA = try XCTUnwrap(appState.beginOpenRouterProvisioning(messageSurface: .settings))
        let flowA = try XCTUnwrap(openRouterCallbackState(from: urlA))

        appState.cancelOpenRouterProvisioning(messageSurface: .settings)
        let urlB = try XCTUnwrap(appState.beginOpenRouterProvisioning(messageSurface: .settings))
        let flowB = try XCTUnwrap(openRouterCallbackState(from: urlB))
        let verifierB = try XCTUnwrap(try secrets.value(for: .openRouterPKCEVerifier))
        let transport = CallbackSurfaceJSONTransport(
            HTTPResponse(statusCode: 500, body: Data(#"{"error":"bad code"}"#.utf8))
        )

        await appState.handleOpenRouterCallback(
            code: "CODE_A",
            flowID: flowA,
            provisioner: OpenRouterKeyProvisioner(transport: transport)
        )

        XCTAssertNotEqual(flowA, flowB)
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertTrue(appState.isOpenRouterProvisioning)
        XCTAssertEqual(try secrets.value(for: .openRouterPKCEVerifier), verifierB)
        XCTAssertEqual(try secrets.value(for: .openRouterPKCEFlowID), flowB)
        XCTAssertNil(appState.llmError)
        XCTAssertNil(appState.llmError(for: .settings))
    }

    func testStatelessOpenRouterCallbackDoesNotDisturbReplacementFlow() async throws {
        let secrets = InMemorySecretStore()
        let appState = makeAppState(secrets: secrets)
        _ = try XCTUnwrap(appState.beginOpenRouterProvisioning(messageSurface: .settings))

        appState.cancelOpenRouterProvisioning(messageSurface: .settings)
        let urlB = try XCTUnwrap(appState.beginOpenRouterProvisioning(messageSurface: .settings))
        let flowB = try XCTUnwrap(openRouterCallbackState(from: urlB))
        let verifierB = try XCTUnwrap(try secrets.value(for: .openRouterPKCEVerifier))
        let transport = CallbackSurfaceJSONTransport(
            HTTPResponse(statusCode: 500, body: Data(#"{"error":"bad code"}"#.utf8))
        )

        await appState.handleOpenRouterCallback(
            code: "CODE_A",
            provisioner: OpenRouterKeyProvisioner(transport: transport)
        )

        XCTAssertEqual(transport.callCount, 0)
        XCTAssertTrue(appState.isOpenRouterProvisioning)
        XCTAssertEqual(try secrets.value(for: .openRouterPKCEVerifier), verifierB)
        XCTAssertEqual(try secrets.value(for: .openRouterPKCEFlowID), flowB)
        XCTAssertNil(appState.llmError)
        XCTAssertNil(appState.llmError(for: .settings))
    }

    func testCanceledSettingsManagedOAuthCallbackDoesNotDisturbReplacementFlow() async throws {
        let secrets = InMemorySecretStore()
        let secondStartResponse = startResponse.replacingOccurrences(of: #""id":"sia_1""#, with: #""id":"sia_2""#)
        let transport = QueueClerkTransport([
            clerkReply(startResponse, clientToken: "client_A"),
            clerkReply(secondStartResponse, clientToken: "client_B")
        ])
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        let managed = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = makeAppState(provider: "managed", secrets: secrets, managedAccount: managed)

        await appState.startManagedGoogleSignIn(openURL: { _ in }, messageSurface: .settings)
        let flowA = try XCTUnwrap(callbackState(from: transport.requests[0].form["redirect_url"]))
        await appState.cancelManagedSignInFlow(messageSurface: .settings)
        await appState.startManagedGoogleSignIn(openURL: { _ in }, messageSurface: .settings)
        let flowB = try XCTUnwrap(callbackState(from: transport.requests[1].form["redirect_url"]))

        await appState.handleManagedOAuthCallback(nonce: "nonce_from_a", flowID: flowA)

        XCTAssertNotEqual(flowA, flowB)
        XCTAssertEqual(transport.callCount, 2)
        XCTAssertEqual(appState.managedSignInStage, .awaitingBrowser)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertEqual(try secrets.value(for: .managedOAuthSignInID), "sia_2")
        XCTAssertEqual(try secrets.value(for: .managedOAuthFlowID), flowB)
        XCTAssertNil(appState.managedError)
        XCTAssertNil(appState.managedError(for: .settings))
    }

    func testStatelessManagedOAuthCallbackDoesNotDisturbReplacementFlow() async throws {
        let secrets = InMemorySecretStore()
        let secondStartResponse = startResponse.replacingOccurrences(of: #""id":"sia_1""#, with: #""id":"sia_2""#)
        let transport = QueueClerkTransport([
            clerkReply(startResponse, clientToken: "client_A"),
            clerkReply(secondStartResponse, clientToken: "client_B")
        ])
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        let managed = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = makeAppState(provider: "managed", secrets: secrets, managedAccount: managed)

        await appState.startManagedGoogleSignIn(openURL: { _ in }, messageSurface: .settings)
        await appState.cancelManagedSignInFlow(messageSurface: .settings)
        await appState.startManagedGoogleSignIn(openURL: { _ in }, messageSurface: .settings)
        let flowB = try XCTUnwrap(callbackState(from: transport.requests[1].form["redirect_url"]))

        await appState.handleManagedOAuthCallback(nonce: "nonce_from_a")

        XCTAssertEqual(transport.callCount, 2)
        XCTAssertEqual(appState.managedSignInStage, .awaitingBrowser)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertEqual(try secrets.value(for: .managedOAuthSignInID), "sia_2")
        XCTAssertEqual(try secrets.value(for: .managedOAuthFlowID), flowB)
        XCTAssertNil(appState.managedError)
        XCTAssertNil(appState.managedError(for: .settings))
    }

    func testCanceledSettingsManagedOAuthCallbackIsIgnored() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([clerkReply(startResponse, clientToken: "client_A")])
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        let managed = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = makeAppState(provider: "managed", secrets: secrets, managedAccount: managed)
        appState.managedError = "setup assistant error"

        await appState.startManagedGoogleSignIn(openURL: { _ in }, messageSurface: .settings)
        await appState.cancelManagedSignInFlow(messageSurface: .settings)
        await appState.handleManagedOAuthCallback(nonce: "nonce_1")

        XCTAssertEqual(appState.managedError, "setup assistant error")
        XCTAssertNil(appState.managedError(for: .settings))
        XCTAssertEqual(appState.managedSignInStage, .idle)
        XCTAssertFalse(appState.isManagedSignedIn)
    }

    func testRelaunchedManagedOAuthCallbackFailureUsesPersistedSettingsSurface() async throws {
        let secrets = InMemorySecretStore()
        let startTransport = QueueClerkTransport([clerkReply(startResponse, clientToken: "client_A")])
        let startClerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: startTransport
        )
        let firstManaged = ManagedAccountService(secrets: secrets, clerk: startClerk)
        let firstLaunch = makeAppState(provider: "managed", secrets: secrets, managedAccount: firstManaged)
        await firstLaunch.startManagedGoogleSignIn(openURL: { _ in }, messageSurface: .settings)
        let flowID = try XCTUnwrap(callbackState(from: startTransport.requests[0].form["redirect_url"]))
        let callbackTransport = QueueClerkTransport([
            clerkReply(#"{"errors":[{"message":"Bad nonce"}]}"#, status: 400, clientToken: "client_B")
        ])
        let callbackClerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: callbackTransport
        )
        let callbackManaged = ManagedAccountService(secrets: secrets, clerk: callbackClerk)
        let relaunched = makeAppState(provider: "managed", secrets: secrets, managedAccount: callbackManaged)

        await relaunched.handleManagedOAuthCallback(nonce: "bad_nonce", flowID: flowID)

        XCTAssertNil(relaunched.managedError)
        XCTAssertNotNil(relaunched.managedError(for: .settings))
        XCTAssertFalse(relaunched.isManagedSignedIn)
    }

    func testManagedOAuthCallbackFailureSurvivesSettingsCloseDuringExchange() async throws {
        let secrets = InMemorySecretStore()
        let startTransport = QueueClerkTransport([clerkReply(startResponse, clientToken: "client_A")])
        let startClerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: startTransport
        )
        let firstManaged = ManagedAccountService(secrets: secrets, clerk: startClerk)
        let firstLaunch = makeAppState(provider: "managed", secrets: secrets, managedAccount: firstManaged)
        await firstLaunch.startManagedGoogleSignIn(openURL: { _ in }, messageSurface: .settings)
        let flowID = try XCTUnwrap(callbackState(from: startTransport.requests[0].form["redirect_url"]))
        let callbackTransport = SuspendedClerkTransport()
        let callbackClerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: callbackTransport
        )
        let callbackManaged = ManagedAccountService(secrets: secrets, clerk: callbackClerk)
        let relaunched = makeAppState(provider: "managed", secrets: secrets, managedAccount: callbackManaged)
        let didStartCallback = expectation(description: "managed oauth callback started")
        callbackTransport.onRequest = {
            didStartCallback.fulfill()
        }
        let callback = Task {
            await relaunched.handleManagedOAuthCallback(nonce: "bad_nonce", flowID: flowID)
        }
        await fulfillment(of: [didStartCallback], timeout: 1)

        relaunched.resetTransientSettingsMessages()
        callbackTransport.resume(with: clerkReply(
            #"{"errors":[{"message":"Bad nonce"}]}"#,
            status: 400,
            clientToken: "client_B"
        ))
        await callback.value

        XCTAssertNil(relaunched.managedError)
        XCTAssertNotNil(relaunched.managedError(for: .settings))

        relaunched.resetTransientSettingsMessages()

        XCTAssertNotNil(relaunched.managedError(for: .settings))
    }
}
