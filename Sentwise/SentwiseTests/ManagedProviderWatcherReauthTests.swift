import XCTest
import SentwiseMail
@testable import Sentwise

private final class WatcherReauthLLMTransport: LLMHTTPTransport, @unchecked Sendable {
    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        HTTPResponse(
            statusCode: 401,
            body: Data(#"{"error":{"type":"unauthenticated","message":"Sign in."}}"#.utf8)
        )
    }

    func getJSON(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            body: Data(
                #"{"userId":"user_marcus","email":"marcus@example.com","subscription":{"plan":"pro","status":"active"}}"#.utf8
            )
        )
    }
}

/// A managed 401 mid-watch pauses the inbox watcher; re-signing in resumes it.
@MainActor
final class ManagedProviderWatcherReauthTests: XCTestCase {

    func testManagedReauthenticationRestoresInboxWatchingAfterWatcherAuthPause() async throws {
        let (appState, _) = makeWatcherReauthFixture()

        XCTAssertTrue(appState.canWatch)
        appState.startWatching()
        await appState.pollInboxOnce()

        XCTAssertEqual(appState.watchStatus, .paused)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertTrue(appState.resumeWatchingAfterManagedReauth)

        appState.managedEmailInput = "marcus@example.com"
        await appState.startManagedSignIn()
        appState.managedCodeInput = "123456"
        await appState.verifyManagedCode()
        for _ in 0..<100 where appState.watchStatus != .watching {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(appState.watchStatus, .watching)
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertFalse(appState.resumeWatchingAfterManagedReauth)

        appState.stopWatching()
    }

    // MARK: - Watcher reauth fixture

    private func watcherReauthPersistence() -> AppStateMemoryPersistence {
        AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "managed",
                llmVerifiedModel: LLMProviderKind.managed.defaultModel,
                managedAccountEmail: "marcus@example.com"
            ),
            processedMessages: {
                var processed = ProcessedMessages()
                processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
                processed.setBaselineUID(account: "me@gmail.com", mailbox: .inbox, uid: 1, uidValidity: 10)
                return processed
            }()
        )
    }

    private func watcherReauthClerk() -> ClerkClient {
        let signInCreatedBody = """
        {
          "response": {
            "id": "sia_1",
            "supported_first_factors": [
              {"strategy": "email_code", "email_address_id": "ema_1"}
            ]
          }
        }
        """
        return ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: ManagedProviderQueueClerkTransport([
                managedProviderClerkResponse(#"{"jwt":"draft.jwt"}"#, clientToken: "client_Y"),
                managedProviderClerkResponse(signInCreatedBody, clientToken: "client_A"),
                managedProviderClerkResponse(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
                managedProviderClerkResponse(
                    #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_2"}}"#,
                    clientToken: "client_C"
                ),
                managedProviderClerkResponse(#"{"jwt":"session.jwt"}"#, clientToken: "client_D")
            ])
        )
    }

    /// An app whose managed session 401s on the first draft, then signs back in
    /// successfully through the email-code flow.
    private func makeWatcherReauthFixture() -> (AppState, InMemorySecretStore) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: "me@gmail.com"): "app-pw",
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = watcherReauthPersistence()
        let clerk = watcherReauthClerk()
        let managedAccount = ManagedAccountService(secrets: secrets, clerk: clerk)
        let llm = LLMService(
            transport: WatcherReauthLLMTransport(),
            managedSessionProvider: managedAccount
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(
                result: .success(()),
                fetchResult: .success([
                    MailMessage(
                        id: 2,
                        uidValidity: 10,
                        from: MailAddress(name: "Alice", email: "alice@example.com"),
                        subject: "Question",
                        date: "",
                        messageID: "<2@example.com>"
                    )
                ]),
                bodyResult: .success(Data("Can you help?".utf8))
            ),
            llm: llm,
            managedAccount: managedAccount,
            reachability: FakeReachabilityMonitor(isOnline: true, hasCurrentPath: false)
        )
        appState.retryRunner = .immediate
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .active,
            capturedAt: Date()
        )
        return (appState, secrets)
    }
}
