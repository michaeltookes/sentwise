import XCTest
@testable import Sentwise

@MainActor
final class ManagedSignInStatusSurfaceTests: XCTestCase {
    func testSuccessfulVerifyKeepsAccountSignedInWhileStatusRefreshRetriesThenSettles() async {
        let expectedStatus = ManagedAccountStatus(
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active)
        )
        let llm = ManagedSignInStatusLLMProvider(results: [
            .failure(.transport("temporary outage")),
            .success(expectedStatus)
        ])
        let appState = makeAppState(llm: llm, verifyResponse: managedProviderClerkResponse(
            #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#,
            clientToken: "client_C"
        ))

        await signIn(appState, code: "123456")

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertNil(appState.managedError(for: .settings), "a /v1/me failure is not a sign-in failure")
        XCTAssertEqual(appState.managedAccountStatusRefreshMessage, AppState.managedStatusRefreshPendingMessage)
        XCTAssertNil(appState.managedAccountStatus)

        let refreshed = await appState.refreshManagedQuota(scheduleRetryOnFailure: false)

        XCTAssertEqual(refreshed, expectedStatus)
        XCTAssertEqual(appState.managedAccountStatus, expectedStatus)
        XCTAssertNil(appState.managedAccountStatusRefreshMessage)
        XCTAssertTrue(appState.isManagedSignedIn)
        let fetchCount = await llm.observedFetchCount()
        XCTAssertEqual(fetchCount, 2)
    }

    func testRetryBudgetExhaustionStopsRetryingAndKeepsAccountSignedIn() async {
        let llm = ManagedSignInStatusLLMProvider(results: [
            .failure(.transport("initial outage")),
            .failure(.transport("retry one outage")),
            .failure(.transport("retry two outage"))
        ])
        let appState = makeAppState(llm: llm, verifyResponse: managedProviderClerkResponse(
            #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#,
            clientToken: "client_C"
        ))

        await signIn(appState, code: "123456")
        XCTAssertEqual(appState.managedAccountStatusRefreshMessage, AppState.managedStatusRefreshPendingMessage)

        appState.scheduleManagedAccountStatusRefreshRetryAfterFailure(delays: [0, 0])
        guard let retryTask = appState.managedAccountStatusRefreshTask else {
            return XCTFail("expected a bounded retry task")
        }
        await retryTask.value

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertEqual(appState.managedAccountStatusRefreshMessage, AppState.managedStatusRefreshExhaustedMessage)
        XCTAssertNil(appState.managedAccountStatusRefreshTask)
        let fetchCount = await llm.observedFetchCount()
        XCTAssertEqual(fetchCount, 3)
    }

    func testConnectivityLossBeforeRetrySettlesWithManualRefreshAvailable() async {
        let llm = ManagedSignInStatusLLMProvider(results: [
            .failure(.transport("initial outage"))
        ])
        let appState = makeAppState(llm: llm, verifyResponse: managedProviderClerkResponse(
            #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#,
            clientToken: "client_C"
        ))

        await signIn(appState, code: "123456")
        XCTAssertEqual(appState.managedAccountStatusRefreshMessage, AppState.managedStatusRefreshPendingMessage)

        appState.scheduleManagedAccountStatusRefreshRetryAfterFailure(delays: [0])
        guard let retryTask = appState.managedAccountStatusRefreshTask else {
            return XCTFail("expected a bounded retry task")
        }
        appState.handleReachabilityChange(false)
        await retryTask.value

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertEqual(appState.managedAccountStatusRefreshMessage, AppState.managedStatusRefreshExhaustedMessage)
        XCTAssertTrue(appState.canManuallyRetryManagedAccountStatusRefresh)
        XCTAssertNil(appState.managedAccountStatusRefreshTask)
        let fetchCount = await llm.observedFetchCount()
        XCTAssertEqual(fetchCount, 1, "connectivity loss stops before another /v1/me fetch")
    }

    func testVerifyStageFailureStaysSignedOutAndUsesSignInFailureSurface() async {
        let llm = ManagedSignInStatusLLMProvider(results: [])
        let appState = makeAppState(llm: llm, verifyResponse: managedProviderClerkResponse(
            #"{"errors":[{"message":"Code is invalid."}]}"#,
            status: 422,
            clientToken: "client_C"
        ))

        await signIn(appState, code: "000000")

        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertEqual(appState.managedError(for: .settings), "Code is invalid.")
        XCTAssertNil(appState.managedAccountStatusRefreshMessage)
        XCTAssertEqual(appState.managedSignInStage, .codeSent)
        let fetchCount = await llm.observedFetchCount()
        XCTAssertEqual(fetchCount, 0)
    }

    private func makeAppState(
        llm: ManagedSignInStatusLLMProvider,
        verifyResponse: ClerkHTTPResponse
    ) -> AppState {
        let secrets = InMemorySecretStore()
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: ManagedProviderQueueClerkTransport([
                managedProviderClerkResponse(
                    #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                    clientToken: "client_A"
                ),
                managedProviderClerkResponse(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
                verifyResponse,
                managedProviderClerkResponse(#"{"jwt":"session.jwt"}"#, clientToken: "client_D")
            ])
        )
        return AppState(
            persistence: AppStateMemoryPersistence(settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                llmProvider: "managed"
            )),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            managedAccount: ManagedAccountService(secrets: secrets, clerk: clerk)
        )
    }

    private func signIn(_ appState: AppState, code: String) async {
        appState.managedEmailInput = "marcus@example.com"
        await appState.startManagedSignIn(messageSurface: .settings)
        appState.managedCodeInput = code
        await appState.verifyManagedCode(messageSurface: .settings)
    }
}

private actor ManagedSignInStatusLLMProvider: LLMProviding {
    private var results: [Result<ManagedAccountStatus?, LLMError>]
    private var fetchCount = 0

    init(results: [Result<ManagedAccountStatus?, LLMError>]) {
        self.results = results
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        LLMResponse(text: "")
    }

    func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
        fetchCount += 1
        return try results.removeFirst().get()
    }

    func observedFetchCount() -> Int { fetchCount }
}
