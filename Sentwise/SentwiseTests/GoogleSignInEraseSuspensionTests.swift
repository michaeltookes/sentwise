import SentwiseMail
import XCTest
@testable import Sentwise

/// Erase-all suspends Google token operations (item 104): a refresh in flight
/// during the erase never retries, loads, or saves a token, so nothing can be
/// restored between the invalidation and the Keychain wipe.
@MainActor
final class GoogleSignInEraseSuspensionTests: XCTestCase {

    private func expiredToken() -> OAuthToken {
        OAuthToken(accessToken: "stale-at", refreshToken: "rt", expiresAt: .distantPast,
                   scope: GoogleOAuth.mailScope, tokenType: "Bearer")
    }

    func testRefreshLandingMidEraseNeverRetriesOrSaves() async throws {
        let store = GmailAuthStore(secrets: InMemorySecretStore())
        try store.saveToken(expiredToken(), for: "me@gmail.com")
        let transport = GatedRefreshTransport()
        let coordinator = GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: "1234-abc.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: transport)
        )

        let refresh = Task { try await coordinator.validAccessToken(for: "me@gmail.com") }
        await fulfillment(of: [transport.didStartRefresh], timeout: 2)

        // Erase begins: invalidate + suspend. The response lands before the Keychain wipe.
        coordinator.invalidateAll()
        transport.completeRefresh(HTTPResponse(statusCode: 200, body: Data(
            #"{"access_token":"late-at","expires_in":3600,"scope":"https://mail.google.com/"}"#.utf8
        )))
        do {
            _ = try await refresh.value
            XCTFail("an erased mailbox must not get a token")
        } catch {
            XCTAssertEqual(error as? GmailAuthError, .notConnected)
        }
        XCTAssertEqual(transport.refreshCount, 1, "no retry against the old refresh token")
        XCTAssertEqual(try store.loadToken(for: "me@gmail.com")?.accessToken, "stale-at", "nothing saved mid-erase")
        await assertNotConnected(try await coordinator.validAccessToken(for: "me@gmail.com"), "suspended: no load")

        // The erase wipes the Keychain, then resumes token operations.
        try store.deleteToken(for: "me@gmail.com")
        coordinator.resumeTokenOperations()
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"), "the deleted token is never restored")
        await assertNotConnected(try await coordinator.validAccessToken(for: "me@gmail.com"), "erased")
    }

    func testEraseWithARefreshInFlightEndsDisconnectedWithNoToken() async throws {
        let secrets = InMemorySecretStore()
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        let store = GmailAuthStore(secrets: secrets)
        try store.saveToken(expiredToken(), for: "me@gmail.com")
        try secrets.set(GoogleMailCredential.marker, for: .mailAppPassword(email: "me@gmail.com"))
        let transport = GatedRefreshTransport()
        appState.googleMailAuth.install(GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: "1234-abc.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: transport)
        ))

        let fetch = Task { () -> Error? in
            do {
                _ = try await appState.mailProvider.fetchRecentMessages(
                    GoogleMailCredential.credentials(email: "me@gmail.com"), mailbox: .inbox, limit: 1
                )
                return nil
            } catch { return error }
        }
        await fulfillment(of: [transport.didStartRefresh], timeout: 2)

        await appState.eraseAllLocalData()
        transport.completeRefresh(HTTPResponse(statusCode: 200, body: Data(
            #"{"access_token":"late-at","expires_in":3600,"scope":"https://mail.google.com/"}"#.utf8
        )))
        let error = await fetch.value

        XCTAssertNotNil(error, "the erased mailbox's poll fails instead of using a token")
        XCTAssertFalse(store.hasToken(for: "me@gmail.com"), "no token restored after the erase")
        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertEqual(transport.refreshCount, 1)
        XCTAssertFalse(appState.googleMailAuth.coordinator?.tokenOperationsSuspended ?? true, "erase resumes when done")
    }

    private func assertNotConnected(
        _ expression: @autoclosure () async throws -> String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected notConnected: \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GmailAuthError, .notConnected, message, file: file, line: line)
        }
    }
}
