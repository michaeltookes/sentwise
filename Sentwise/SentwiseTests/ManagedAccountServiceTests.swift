import XCTest
@testable import Sentwise

final class ManagedAccountServiceTests: XCTestCase {

    private func service(_ transport: ClerkHTTPTransport, secrets: SecretStore) -> ManagedAccountService {
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        return ManagedAccountService(secrets: secrets, clerk: clerk)
    }

    func testNotSignedInThrowsWhenMintingToken() async {
        let account = service(QueueClerkTransport([]), secrets: InMemorySecretStore())
        do {
            _ = try await account.currentSessionToken()
            XCTFail("Expected managedNotSignedIn")
        } catch LLMError.managedNotSignedIn {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFullSignInStoresCredentialsAndMintsToken() async throws {
        let secrets = InMemorySecretStore()
        // Full flow, in order:
        //   startSignIn:    create -> prepare
        //   completeSignIn: attempt -> tokens (completeSignIn verifies by minting once)
        //   currentSessionToken: tokens (a second, fresh mint)
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            clerkReply(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_C"),
            clerkReply(#"{"jwt":"eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyX2VtYWlsIn0.signature"}"#, clientToken: "client_D"),
            clerkReply(#"{"jwt":"second.jwt"}"#, clientToken: "client_E")
        ])
        let account = service(transport, secrets: secrets)

        try await account.startSignIn(email: "marcus@example.com")
        let result = try await account.completeSignIn(code: "123456")

        let signedIn = await account.isSignedIn
        XCTAssertTrue(signedIn)
        XCTAssertEqual(result.accountIdentifier, "clerk-user:user_email")
        // Device token + session id persisted; the latest rotated token is stored.
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_D")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")

        // A subsequent token mint returns a fresh jwt and rotates the device token.
        let token = try await account.currentSessionToken()
        XCTAssertEqual(token, "second.jwt")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_E")
    }

    func testFullSignInClearsPersistentInvalidationMarker() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedCredentialsInvalidated: "1",
            .managedClientToken: "stale_client",
            .managedSessionID: "stale_session"
        ])
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            clerkReply(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_C"),
            clerkReply(#"{"jwt":"first.jwt"}"#, clientToken: "client_D")
        ])
        let account = service(transport, secrets: secrets)

        try await account.startSignIn(email: "marcus@example.com")
        try await account.completeSignIn(code: "123456")

        let signedIn = await account.isSignedIn
        XCTAssertTrue(signedIn)
        XCTAssertEqual(transport.requests.first?.headers["authorization"], "Bearer ")
        XCTAssertNil(try secrets.value(for: .managedCredentialsInvalidated))
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_D")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
    }

    func testStartSignInPersistsCreatedTokenWhenPrepareFails() async throws {
        let secrets = InMemorySecretStore()
        let startedResponse = #"{"response":{"id":"sia_1","supported_first_factors":["#
            + #"{"strategy":"email_code","email_address_id":"ema_1"}]}}"#
        let transport = QueueClerkTransport([
            clerkReply(startedResponse, clientToken: "client_A"),
            clerkReply(#"{"errors":[{"message":"temporarily unavailable"}]}"#, status: 503),
            clerkReply(startedResponse, clientToken: "client_B"),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_C")
        ])
        let account = service(transport, secrets: secrets)

        do {
            try await account.startSignIn(email: "marcus@example.com")
            XCTFail("Expected prepare failure")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(clientToken, "client_A")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_A")

        try await account.startSignIn(email: "marcus@example.com")

        XCTAssertEqual(transport.requests[2].headers["authorization"], "Bearer client_A")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_C")
    }

    func testStartSignInPersistsRotatedTokenFromCreationFailure() async throws {
        let secrets = InMemorySecretStore()
        let startedResponse = #"{"response":{"id":"sia_1","supported_first_factors":["#
            + #"{"strategy":"email_code","email_address_id":"ema_1"}]}}"#
        let transport = QueueClerkTransport([
            clerkReply(#"{"errors":[{"message":"temporarily unavailable"}]}"#, status: 503, clientToken: "client_A"),
            clerkReply(startedResponse, clientToken: "client_B"),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_C")
        ])
        let account = service(transport, secrets: secrets)

        do {
            try await account.startSignIn(email: "marcus@example.com")
            XCTFail("Expected creation failure")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(clientToken, "client_A")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_A")

        try await account.startSignIn(email: "marcus@example.com")

        XCTAssertEqual(transport.requests[1].headers["authorization"], "Bearer client_A")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_C")
    }

    func testStartSignInPersistsRotatedTokenFromFallbackSignUpCreationFailure() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"errors":[{"code":"form_identifier_not_found","message":"not found"}]}"#,
                status: 422,
                clientToken: "client_A"
            ),
            clerkReply(#"{"errors":[{"message":"temporarily unavailable"}]}"#, status: 503, clientToken: "client_B")
        ])
        let account = service(transport, secrets: secrets)

        do {
            try await account.startSignIn(email: "marcus@example.com")
            XCTFail("Expected sign-up creation failure")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(clientToken, "client_B")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transport.requests[1].headers["authorization"], "Bearer client_A")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_B")
    }

    func testStartSignInPersistsTokenBeforeFallbackSignUpTransportFailure() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport(results: [
            .success(clerkReply(
                #"{"errors":[{"code":"form_identifier_not_found","message":"not found"}]}"#,
                status: 422,
                clientToken: "client_A"
            )),
            .failure(URLError(.timedOut))
        ])
        let account = service(transport, secrets: secrets)

        do {
            try await account.startSignIn(email: "marcus@example.com")
            XCTFail("Expected sign-up transport failure")
        } catch ClerkError.transport(_, let clientToken) {
            XCTAssertEqual(clientToken, "client_A")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transport.requests[1].headers["authorization"], "Bearer client_A")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_A")
    }

    func testStartSignInPersistsRotatedTokenFromPrepareFailure() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            clerkReply(
                #"{"errors":[{"message":"temporarily unavailable"}]}"#,
                status: 503,
                clientToken: "client_B"
            )
        ])
        let account = service(transport, secrets: secrets)

        do {
            try await account.startSignIn(email: "marcus@example.com")
            XCTFail("Expected prepare failure")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(clientToken, "client_B")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_B")
    }

    func testCompleteSignInKeepsPendingAndDoesNotStoreSessionWhenMintFails() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            clerkReply(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_C"),
            clerkReply(#"{"errors":[{"message":"offline"}]}"#, status: 503, clientToken: "client_D"),
            clerkReply(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_E"),
            clerkReply(#"{"jwt":"retry.jwt"}"#, clientToken: "client_F")
        ])
        let account = service(transport, secrets: secrets)

        try await account.startSignIn(email: "marcus@example.com")
        do {
            try await account.completeSignIn(code: "123456")
            XCTFail("Expected token mint failure")
        } catch LLMError.transport {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let awaited1 = await account.isSignedIn
        XCTAssertFalse(awaited1)
        XCTAssertNil(try secrets.value(for: .managedSessionID))
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_D")

        try await account.completeSignIn(code: "123456")

        let awaited2 = await account.isSignedIn
        XCTAssertTrue(awaited2)
        XCTAssertEqual(transport.requests[2].headers["authorization"], "Bearer client_B")
        XCTAssertEqual(transport.requests[3].headers["authorization"], "Bearer client_C")
        XCTAssertEqual(transport.requests[4].headers["authorization"], "Bearer client_D")
        XCTAssertEqual(transport.requests[5].headers["authorization"], "Bearer client_E")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_F")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
    }

    func testCompleteSignInRetriesWithRotatedTokenAfterAuthMintFailure() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            clerkReply(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_C"),
            clerkReply(#"{"errors":[{"message":"expired"}]}"#, status: 401, clientToken: "client_D"),
            clerkReply(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_E"),
            clerkReply(#"{"jwt":"retry.jwt"}"#, clientToken: "client_F")
        ])
        let account = service(transport, secrets: secrets)

        try await account.startSignIn(email: "marcus@example.com")
        do {
            try await account.completeSignIn(code: "123456")
            XCTFail("Expected auth mint failure")
        } catch LLMError.managedNotSignedIn {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedInAfterFailure = await account.isSignedIn
        XCTAssertFalse(signedInAfterFailure)
        XCTAssertNil(try secrets.value(for: .managedSessionID))
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_D")

        try await account.completeSignIn(code: "123456")

        XCTAssertEqual(transport.requests[2].headers["authorization"], "Bearer client_B")
        XCTAssertEqual(transport.requests[3].headers["authorization"], "Bearer client_C")
        XCTAssertEqual(transport.requests[4].headers["authorization"], "Bearer client_D")
        XCTAssertEqual(transport.requests[5].headers["authorization"], "Bearer client_E")
        let signedInAfterRetry = await account.isSignedIn
        XCTAssertTrue(signedInAfterRetry)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_F")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
    }

    func testCompleteSignInRetriesWithMintedTokenAfterSuccessfulMintPersistenceFailure() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [:])
        secrets.failOnSetKeys = [.managedClientToken]
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            clerkReply(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_C"),
            clerkReply(#"{"jwt":"first.jwt"}"#, clientToken: "client_D"),
            clerkReply(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_E"),
            clerkReply(#"{"jwt":"retry.jwt"}"#, clientToken: "client_F")
        ])
        let account = service(transport, secrets: secrets)

        try await account.startSignIn(email: "marcus@example.com")
        do {
            try await account.completeSignIn(code: "123456")
            XCTFail("Expected client-token persistence failure")
        } catch ManagedAccountTestSecretError.setDenied {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(try secrets.value(for: .managedSessionID))

        secrets.failOnSetKeys = []
        try await account.completeSignIn(code: "123456")

        XCTAssertEqual(transport.requests[2].headers["authorization"], "Bearer client_B")
        XCTAssertEqual(transport.requests[3].headers["authorization"], "Bearer client_C")
        XCTAssertEqual(transport.requests[4].headers["authorization"], "Bearer client_D")
        XCTAssertEqual(transport.requests[5].headers["authorization"], "Bearer client_E")
        let awaited3 = await account.isSignedIn
        XCTAssertTrue(awaited3)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_F")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
    }

    func testCompleteSignInRetriesWithRotatedTokenAfterFailedOTPAttempt() async throws {
        let secrets = InMemorySecretStore()
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            clerkReply(#"{"errors":[{"message":"Code is invalid."}]}"#, status: 422, clientToken: "client_C"),
            clerkReply(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#, clientToken: "client_D"),
            clerkReply(#"{"jwt":"retry.jwt"}"#, clientToken: "client_E")
        ])
        let account = service(transport, secrets: secrets)

        try await account.startSignIn(email: "marcus@example.com")
        do {
            try await account.completeSignIn(code: "000000")
            XCTFail("Expected failed OTP attempt")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(clientToken, "client_C")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_C")
        try await account.completeSignIn(code: "123456")

        let awaited4 = await account.isSignedIn
        XCTAssertTrue(awaited4)
        XCTAssertEqual(transport.requests[2].headers["authorization"], "Bearer client_B")
        XCTAssertEqual(transport.requests[3].headers["authorization"], "Bearer client_C")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_E")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
    }
}
