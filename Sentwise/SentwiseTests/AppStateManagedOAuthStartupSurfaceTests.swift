import XCTest
@testable import Sentwise

@MainActor
final class AppStateManagedOAuthStartupSurfaceTests: XCTestCase {

    private let startResponse =
        #"{"response":{"id":"sia_1","first_factor_verification":"#
            + #"{"external_verification_redirect_url":"https://accounts.google.com/o/oauth2/auth?x=1"}}}"#

    private func makeAppState(
        secrets: SecretStore,
        managedAccount: ManagedAccountService
    ) -> AppState {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed"
        ))
        return AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            managedAccount: managedAccount
        )
    }

    func testSettingsGoogleSignInAbortsWhenCallbackSurfaceCannotBePersisted() async throws {
        let secrets = AppStateFailingSecretStore()
        secrets.failOnSet = .managedOAuthMessageSurface
        let transport = QueueClerkTransport([clerkReply(startResponse, clientToken: "client_A")])
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        let managed = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = makeAppState(secrets: secrets, managedAccount: managed)
        var openedURLs: [URL] = []

        await appState.startManagedGoogleSignIn(
            openURL: { openedURLs.append($0) },
            messageSurface: .settings
        )

        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertEqual(appState.managedSignInStage, .idle)
        XCTAssertFalse(appState.isManagedBusy)
        XCTAssertNil(appState.managedError)
        XCTAssertNotNil(appState.managedError(for: .settings))
        XCTAssertNil(try secrets.value(for: .managedOAuthFlowID))
        XCTAssertNil(try secrets.value(for: .managedOAuthMessageSurface))
    }
}
