import XCTest
@testable import Sentwise

/// Unit tests for `ManagedAccountService`'s Google (OAuth) sign-in (item 59),
/// driven end to end against the shared fake Clerk transport.
final class ManagedAccountServiceOAuthTests: XCTestCase {

    private func makeClerk(_ transport: QueueClerkTransport) -> ClerkClient {
        ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
    }

    private let startResponse =
        #"{"response":{"id":"sia_1","first_factor_verification":"#
            + #"{"external_verification_redirect_url":"https://accounts.google.com/o/oauth2/auth?x=1"}}}"#
    private let emailStartResponse =
        #"{"response":{"id":"email_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#
    private let emailPrepareResponse = #"{"response":{"id":"email_1"}}"#
    private let oauthUserJWT = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyX29hdXRoIn0.signature"

    func testStartGoogleSignInReturnsURLAndPersistsClientToken() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([clerkReply(startResponse, clientToken: "client_A")])
        let service = ManagedAccountService(secrets: secrets, clerk: makeClerk(transport))

        let url = try await service.startGoogleSignIn(redirectURL: "sentwise://oauth-callback")

        XCTAssertEqual(url.absoluteString, "https://accounts.google.com/o/oauth2/auth?x=1")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_A")
    }

    func testCompleteGoogleSignInStoresSessionAndReturnsIdentifier() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(startResponse, clientToken: "client_A"),
            clerkReply(
                #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1","identifier":"marcus@example.com"}}"#,
                clientToken: "client_B"
            ),
            clerkReply(#"{"jwt":""# + oauthUserJWT + #""}"#, clientToken: "client_C")
        ])
        let service = ManagedAccountService(secrets: secrets, clerk: makeClerk(transport))

        _ = try await service.startGoogleSignIn(redirectURL: "sentwise://oauth-callback")
        let result = try await service.completeGoogleSignIn(rotatingTokenNonce: "nonce_1")

        XCTAssertEqual(result.displayIdentifier, "marcus@example.com")
        XCTAssertEqual(result.accountIdentifier, "clerk-user:user_oauth")
        let signedIn = await service.isSignedIn
        XCTAssertTrue(signedIn)
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_C")
    }

    func testCompleteGoogleSignInAfterRelaunchRestoresPendingHandle() async throws {
        let secrets = InMemorySecretStore()
        let startTransport = QueueClerkTransport([clerkReply(startResponse, clientToken: "client_A")])
        let startedService = ManagedAccountService(secrets: secrets, clerk: makeClerk(startTransport))

        _ = try await startedService.startGoogleSignIn(redirectURL: "sentwise://oauth-callback")
        XCTAssertEqual(try secrets.value(for: .managedOAuthSignInID), "sia_1")

        let callbackTransport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1","identifier":"marcus@example.com"}}"#,
                clientToken: "client_B"
            ),
            clerkReply(#"{"jwt":"jwt.value"}"#, clientToken: "client_C")
        ])
        let relaunchedService = ManagedAccountService(secrets: secrets, clerk: makeClerk(callbackTransport))

        let result = try await relaunchedService.completeGoogleSignIn(rotatingTokenNonce: "nonce_1")

        XCTAssertEqual(result.displayIdentifier, "marcus@example.com")
        XCTAssertEqual(result.accountIdentifier, "clerk-session:sess_1")
        let signedIn = await relaunchedService.isSignedIn
        XCTAssertTrue(signedIn)
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_C")
        XCTAssertNil(try secrets.value(for: .managedOAuthSignInID))
    }

    func testCompleteGoogleSignInWithoutStartThrows() async {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([])
        let service = ManagedAccountService(secrets: secrets, clerk: makeClerk(transport))

        do {
            _ = try await service.completeGoogleSignIn(rotatingTokenNonce: "nonce")
            XCTFail("Expected malformedResponse")
        } catch ClerkError.malformedResponse(let message, _) {
            XCTAssertEqual(message, "no oauth sign-in in progress")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelSignInClearsPendingGoogleCallback() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([clerkReply(startResponse, clientToken: "client_A")])
        let service = ManagedAccountService(secrets: secrets, clerk: makeClerk(transport))

        _ = try await service.startGoogleSignIn(redirectURL: "sentwise://oauth-callback")
        await service.cancelSignIn()

        do {
            _ = try await service.completeGoogleSignIn(rotatingTokenNonce: "nonce_1")
            XCTFail("Expected malformedResponse")
        } catch ClerkError.malformedResponse(let message, _) {
            XCTAssertEqual(message, "no oauth sign-in in progress")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.callCount, 1, "cancelled callbacks should fail before another Clerk request")
        let signedIn = await service.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedSessionID))
        XCTAssertNil(try secrets.value(for: .managedOAuthSignInID))
    }

    func testStartingGoogleSignInClearsPendingEmailCodeSignIn() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(emailStartResponse, clientToken: "client_A"),
            clerkReply(emailPrepareResponse, clientToken: "client_B"),
            clerkReply(startResponse, clientToken: "client_C")
        ])
        let service = ManagedAccountService(secrets: secrets, clerk: makeClerk(transport))

        try await service.startSignIn(email: "marcus@example.com")
        _ = try await service.startGoogleSignIn(redirectURL: "sentwise://oauth-callback")

        do {
            try await service.completeSignIn(code: "123456")
            XCTFail("Expected malformedResponse")
        } catch ClerkError.malformedResponse(let message, _) {
            XCTAssertEqual(message, "no sign-in in progress")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartingEmailCodeSignInClearsPendingGoogleSignIn() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(startResponse, clientToken: "client_A"),
            clerkReply(emailStartResponse, clientToken: "client_B"),
            clerkReply(emailPrepareResponse, clientToken: "client_C")
        ])
        let service = ManagedAccountService(secrets: secrets, clerk: makeClerk(transport))

        _ = try await service.startGoogleSignIn(redirectURL: "sentwise://oauth-callback")
        try await service.startSignIn(email: "marcus@example.com")

        do {
            _ = try await service.completeGoogleSignIn(rotatingTokenNonce: "nonce_1")
            XCTFail("Expected malformedResponse")
        } catch ClerkError.malformedResponse(let message, _) {
            XCTAssertEqual(message, "no oauth sign-in in progress")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
