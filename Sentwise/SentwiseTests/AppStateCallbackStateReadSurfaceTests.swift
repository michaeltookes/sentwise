import XCTest
@testable import Sentwise

private final class StateReadSurfaceJSONTransport: LLMHTTPTransport, @unchecked Sendable {
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
final class AppStateCallbackStateReadSurfaceTests: XCTestCase {

    private func makeAppState(
        provider: String = "managed",
        secrets: SecretStore,
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

    func testOpenRouterStateReadFailureReportsBothSurfacesWhenSurfaceCannotBeRead() async throws {
        let secrets = AppStateFailingSecretStore(seed: [
            .openRouterPKCEVerifier: "VER",
            .openRouterPKCEMessageSurface: "settings",
            .openRouterPKCEFlowID: "flow_1"
        ])
        secrets.failOnValue = [.openRouterPKCEMessageSurface, .openRouterPKCEFlowID]
        let appState = makeAppState(secrets: secrets)
        let transport = StateReadSurfaceJSONTransport(
            HTTPResponse(statusCode: 200, body: Data(#"{"key":"sk-or-xyz"}"#.utf8))
        )

        await appState.handleOpenRouterCallback(
            code: "CODE",
            flowID: "flow_1",
            provisioner: OpenRouterKeyProvisioner(transport: transport)
        )

        XCTAssertEqual(transport.callCount, 0)
        XCTAssertNotNil(appState.llmError)
        XCTAssertNotNil(appState.llmError(for: .settings))
    }

    func testManagedOAuthStateReadFailureReportsBothSurfacesWhenSurfaceCannotBeRead() async throws {
        let secrets = AppStateFailingSecretStore(seed: [
            .managedOAuthSignInID: "sia_1",
            .managedOAuthMessageSurface: "settings",
            .managedOAuthFlowID: "flow_1"
        ])
        secrets.failOnValue = [.managedOAuthMessageSurface, .managedOAuthFlowID]
        let response = #"{"response":{"status":"complete","created_session_id":"sess_1","identifier":"m@example.com"}}"#
        let transport = QueueClerkTransport([clerkReply(response, clientToken: "client_A")])
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        let managed = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = makeAppState(provider: "managed", secrets: secrets, managedAccount: managed)

        await appState.handleManagedOAuthCallback(nonce: "nonce_1", flowID: "flow_1")

        XCTAssertEqual(transport.callCount, 0)
        XCTAssertNotNil(appState.managedError)
        XCTAssertNotNil(appState.managedError(for: .settings))
        XCTAssertFalse(appState.isManagedSignedIn)
    }
}
