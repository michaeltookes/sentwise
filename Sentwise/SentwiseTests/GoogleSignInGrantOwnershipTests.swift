import SentwiseMail
import XCTest
@testable import Sentwise

/// A superseded Google attempt cleans up only its own grant (item 104): it
/// never deletes or revokes a replacement grant a newer attempt connected.
@MainActor
final class GoogleSignInGrantOwnershipTests: XCTestCase {

    private let state = "FIXED-STATE"

    private func exchange(access: String, refresh: String) -> HTTPResponse {
        let json = """
        {"access_token":"\(access)","refresh_token":"\(refresh)","expires_in":3600,"token_type":"Bearer",\
        "scope":"https://mail.google.com/ openid","id_token":"\(GmailAuthCoordinatorTests.idToken(email: "me@gmail.com"))"}
        """
        return HTTPResponse(statusCode: 200, body: Data(json.utf8))
    }

    func testOlderAttemptFailingAfterANewerOneConnectedLeavesTheNewGrantAlone() async throws {
        let secrets = InMemorySecretStore()
        let provider = FirstVerifyGatedMailProvider()
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        let store = GmailAuthStore(secrets: secrets)
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data()))
        transport.responses = [exchange(access: "at-A", refresh: "rt-A"), exchange(access: "at-B", refresh: "rt-B")]
        appState.googleMailAuth.install(GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: "1234-abc.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:1", params: ["code": "c", "state": self.state]) },
            browser: SpyBrowser(),
            makeState: { self.state }
        ))

        // Attempt A signs in and is verifying when attempt B starts and connects.
        let attemptA = Task { await appState.connectWithGoogle(loginHint: "me@gmail.com") }
        await fulfillment(of: [provider.didStartFirstVerification], timeout: 2)
        let connectedB = await appState.connectWithGoogle(loginHint: "me@gmail.com")
        XCTAssertTrue(connectedB)
        XCTAssertEqual(try store.loadToken(for: "me@gmail.com")?.refreshToken, "rt-B")

        // A's verification fails afterwards.
        provider.completeFirstVerification(with: .failure(MailError.authenticationFailed("[ALERT] nope")))
        let connectedA = await attemptA.value

        XCTAssertFalse(connectedA)
        XCTAssertEqual(try store.loadToken(for: "me@gmail.com")?.refreshToken, "rt-B", "the newer grant survives")
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertTrue(appState.activeAccountUsesGoogleSignIn)
        XCTAssertFalse(transport.requests.contains { $0.url == GoogleOAuth.revocationEndpoint }, "nothing is revoked")
    }
}

/// Suspends only the first `verifyConnection`; later ones succeed at once.
final class FirstVerifyGatedMailProvider: MailProvider, @unchecked Sendable {
    let didStartFirstVerification = XCTestExpectation(description: "first verification started")
    private let lock = NSLock()
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Error>?

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        lock.lock()
        calls += 1
        let isFirst = calls == 1
        lock.unlock()
        guard isFirst else { return }
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            didStartFirstVerification.fulfill()
        }
    }

    func completeFirstVerification(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, limit: Int
    ) async throws -> [MailMessage] { [] }

    func fetchBodyText(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, uid: UInt32, expectedUIDValidity: UInt32?
    ) async throws -> Data { Data() }

    func appendMessage(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, rfc822: Data, flags: [MailFlag]
    ) async throws {}
}
