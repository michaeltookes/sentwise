import XCTest
@testable import Sentwise

/// Session-token minting, invalidation, and sign-out behavior of `ManagedAccountService`.
final class ManagedAccountServiceSessionTests: XCTestCase {

    private func service(_ transport: ClerkHTTPTransport, secrets: SecretStore) -> ManagedAccountService {
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        return ManagedAccountService(secrets: secrets, clerk: clerk)
    }

    func testCurrentSessionTokenInvalidatesStoredCredentialsOnAuthFailure() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(
            QueueClerkTransport([clerkReply(#"{"errors":[{"message":"expired"}]}"#, status: 401)]),
            secrets: secrets
        )

        do {
            _ = try await account.currentSessionToken()
            XCTFail("Expected managedNotSignedIn")
        } catch LLMError.managedNotSignedIn {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let awaited5 = await account.isSignedIn
        XCTAssertFalse(awaited5)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testCurrentSessionTokenPersistsRotatedClientTokenFromNonAuthMintFailure() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(
            QueueClerkTransport([
                clerkReply(#"{"errors":[{"message":"temporarily unavailable"}]}"#, status: 503, clientToken: "client_Y")
            ]),
            secrets: secrets
        )

        do {
            _ = try await account.currentSessionToken()
            XCTFail("Expected transport error")
        } catch LLMError.transport {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let awaited6 = await account.isSignedIn
        XCTAssertTrue(awaited6)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Y")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testInvalidateSessionMarksAccountSignedOutWhenKeychainRemovalFails() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        let awaited7 = await account.isSignedIn
        XCTAssertTrue(awaited7)
        await account.invalidateSession()

        let awaited8 = await account.isSignedIn
        XCTAssertFalse(awaited8)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testStartSignInAfterInvalidationDoesNotEchoStaleStoredClientToken() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let startedResponse = #"{"response":{"id":"sia_1","supported_first_factors":["#
            + #"{"strategy":"email_code","email_address_id":"ema_1"}]}}"#
        let transport = QueueClerkTransport([
            clerkReply(startedResponse, clientToken: "client_A"),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B")
        ])
        let account = service(transport, secrets: secrets)

        await account.invalidateSession()
        try await account.startSignIn(email: "marcus@example.com")

        XCTAssertEqual(transport.requests.first?.headers["authorization"], "Bearer ")
        let awaited9 = await account.isSignedIn
        XCTAssertFalse(awaited9)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_B")
    }

    func testStartSignInAfterInvalidationReusesFreshReauthTokenOnRetry() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "stale_client",
            .managedSessionID: "stale_session"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let startedResponse = #"{"response":{"id":"sia_1","supported_first_factors":["#
            + #"{"strategy":"email_code","email_address_id":"ema_1"}]}}"#
        let transport = QueueClerkTransport([
            clerkReply(startedResponse, clientToken: "client_A"),
            clerkReply(#"{"errors":[{"message":"temporarily unavailable"}]}"#, status: 503, clientToken: "client_B"),
            clerkReply(startedResponse, clientToken: "client_C"),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_D")
        ])
        let account = service(transport, secrets: secrets)

        await account.invalidateSession()
        do {
            try await account.startSignIn(email: "marcus@example.com")
            XCTFail("Expected prepare failure")
        } catch ClerkError.http(let status, _, let clientToken) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(clientToken, "client_B")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transport.requests[0].headers["authorization"], "Bearer ")
        XCTAssertEqual(transport.requests[1].headers["authorization"], "Bearer client_A")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_B")
        XCTAssertEqual(try secrets.value(for: .managedReauthenticationClientToken), "client_B")

        try await account.startSignIn(email: "marcus@example.com")

        XCTAssertEqual(transport.requests[2].headers["authorization"], "Bearer client_B")
        XCTAssertEqual(transport.requests[3].headers["authorization"], "Bearer client_C")
        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testCurrentSessionTokenSurfacesRotatedClientTokenPersistenceFailure() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnSetKeys = [.managedClientToken]
        let account = service(
            QueueClerkTransport([clerkReply(#"{"jwt":"fresh.jwt"}"#, clientToken: "client_Y")]),
            secrets: secrets
        )

        do {
            _ = try await account.currentSessionToken()
            XCTFail("Expected client-token persistence failure")
        } catch ManagedAccountTestSecretError.setDenied {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testCurrentSessionTokenDoesNotRestoreClientTokenAfterSignOutDuringMint() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let transport = SuspendedClerkTransport()
        let requestStarted = expectation(description: "mint request started")
        transport.onRequest = { requestStarted.fulfill() }
        let account = service(transport, secrets: secrets)

        let tokenTask = Task { try await account.currentSessionToken() }
        await fulfillment(of: [requestStarted], timeout: 1.0)
        try await account.signOut(revokeServerSession: false)
        let awaited10 = await account.isSignedIn
        XCTAssertFalse(awaited10)

        transport.resume(with: clerkReply(#"{"jwt":"fresh.jwt"}"#, clientToken: "client_Y"))
        do {
            _ = try await tokenTask.value
            XCTFail("Expected managedNotSignedIn")
        } catch LLMError.managedNotSignedIn {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testCurrentSessionTokenSerializesRotatingTokenMints() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let transport = MultiSuspendedClerkTransport()
        let firstStarted = expectation(description: "first mint request started")
        let secondStarted = expectation(description: "second mint request started")
        transport.onRequest = { requestNumber in
            if requestNumber == 1 {
                firstStarted.fulfill()
            } else if requestNumber == 2 {
                secondStarted.fulfill()
            }
        }
        let account = service(transport, secrets: secrets)

        let firstTask = Task { try await account.currentSessionToken() }
        await fulfillment(of: [firstStarted], timeout: 1.0)

        let secondTask = Task { try await account.currentSessionToken() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requestCount, 1)

        transport.resumeNext(with: clerkReply(#"{"jwt":"first.jwt"}"#, clientToken: "client_Y"))
        let awaited11 = try await firstTask.value
        XCTAssertEqual(awaited11, "first.jwt")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Y")

        await fulfillment(of: [secondStarted], timeout: 1.0)
        XCTAssertEqual(transport.authorizationHeader(at: 1), "Bearer client_Y")

        transport.resumeNext(with: clerkReply(#"{"jwt":"second.jwt"}"#, clientToken: "client_Z"))
        let awaited12 = try await secondTask.value
        XCTAssertEqual(awaited12, "second.jwt")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Z")
    }

    func testSignOutDoesNotWaitForInFlightMintButRevocationUsesRotatedClientToken() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let transport = MultiSuspendedClerkTransport()
        let mintStarted = expectation(description: "mint request started")
        let revocationStarted = expectation(description: "revocation request started")
        transport.onRequest = { requestNumber in
            if requestNumber == 1 {
                mintStarted.fulfill()
            } else if requestNumber == 2 {
                revocationStarted.fulfill()
            }
        }
        let account = service(transport, secrets: secrets)

        let tokenTask = Task { try await account.currentSessionToken() }
        await fulfillment(of: [mintStarted], timeout: 1.0)

        let signOutTask = Task { try await account.signOut(revokeServerSession: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requestCount, 1)
        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))

        transport.resumeNext(with: clerkReply(#"{"jwt":"fresh.jwt"}"#, clientToken: "client_Y"))
        do {
            _ = try await tokenTask.value
            XCTFail("Expected managedNotSignedIn")
        } catch LLMError.managedNotSignedIn {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try await signOutTask.value
        await fulfillment(of: [revocationStarted], timeout: 1.0)
        XCTAssertEqual(transport.url(at: 1)?.path, "/v1/client/sessions/sess_X/remove")
        XCTAssertEqual(transport.authorizationHeader(at: 1), "Bearer client_Y")
        transport.resumeNext(with: ClerkHTTPResponse(statusCode: 200, headers: [:], body: Data()))
    }

    func testSignOutUsesUnpersistedRotatedClientTokenAfterMintPersistenceFailure() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnSetKeys = [.managedClientToken]
        let transport = MultiSuspendedClerkTransport()
        let mintStarted = expectation(description: "mint request started")
        let revocationStarted = expectation(description: "revocation request started")
        transport.onRequest = { requestNumber in
            if requestNumber == 1 {
                mintStarted.fulfill()
            } else if requestNumber == 2 {
                revocationStarted.fulfill()
            }
        }
        let account = service(transport, secrets: secrets)

        let tokenTask = Task { try await account.currentSessionToken() }
        await fulfillment(of: [mintStarted], timeout: 1.0)
        transport.resumeNext(with: clerkReply(#"{"jwt":"fresh.jwt"}"#, clientToken: "client_Y"))

        do {
            _ = try await tokenTask.value
            XCTFail("Expected token persistence failure")
        } catch ManagedAccountTestSecretError.setDenied {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        try await account.signOut(revokeServerSession: true)

        await fulfillment(of: [revocationStarted], timeout: 1.0)
        XCTAssertEqual(transport.url(at: 1)?.path, "/v1/client/sessions/sess_X/remove")
        XCTAssertEqual(transport.authorizationHeader(at: 1), "Bearer client_Y")
        transport.resumeNext(with: ClerkHTTPResponse(statusCode: 200, headers: [:], body: Data()))
    }

    func testSignOutClearsStoredCredentials() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(QueueClerkTransport([]), secrets: secrets)

        try await account.signOut()

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testSignOutRevokesServerSessionThenClearsCredentials() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let transport = RecordingClerkTransport()
        let revoked = expectation(description: "server-side session revocation POST")
        transport.onPost = { url in
            if url.absoluteString.contains("/v1/client/sessions/sess_X/remove") {
                revoked.fulfill()
            }
        }
        let account = service(transport, secrets: secrets)

        // Revocation is off by default under test/hunt runtimes; opt in explicitly.
        try await account.signOut(revokeServerSession: true)

        // Local cleanup does not wait on the fire-and-forget revocation.
        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))

        await fulfillment(of: [revoked], timeout: 2.0)
    }

    func testSignOutProceedsWhenServerRevocationFails() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let transport = RecordingClerkTransport()
        transport.result = .failure(URLError(.notConnectedToInternet))
        let account = service(transport, secrets: secrets)

        // A failed revocation network call must not throw from, or block, sign-out.
        try await account.signOut(revokeServerSession: true)

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testSignOutSkipsServerRevocationWhenNotRequested() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let transport = RecordingClerkTransport()
        let account = service(transport, secrets: secrets)

        // Default under test/hunt runtimes: no network revocation is attempted.
        try await account.signOut(revokeServerSession: false)

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        // Give any stray detached task a chance to run before asserting none did.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(transport.recordedURLs.isEmpty)
    }

    func testCurrentSessionTokenPersistsRotatedClientTokenFromMalformedMintResponse() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let account = service(
            QueueClerkTransport([
                clerkReply(#"{"unexpected":"shape"}"#, clientToken: "client_Y")
            ]),
            secrets: secrets
        )

        do {
            _ = try await account.currentSessionToken()
            XCTFail("Expected transport error")
        } catch LLMError.transport {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedIn = await account.isSignedIn
        XCTAssertTrue(signedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Y")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testProxyInvalidationSkipsNewerReauthenticatedSession() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let startedResponse = #"{"response":{"id":"sia_1","supported_first_factors":["#
            + #"{"strategy":"email_code","email_address_id":"ema_1"}]}}"#
        let transport = QueueClerkTransport([
            clerkReply(#"{"jwt":"old.jwt"}"#, clientToken: "client_Y"),
            clerkReply(startedResponse, clientToken: "client_A"),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
            clerkReply(#"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_2"}}"#, clientToken: "client_C"),
            clerkReply(#"{"jwt":"new.jwt"}"#, clientToken: "client_D")
        ])
        let account = service(transport, secrets: secrets)

        let oldSession = try await account.currentManagedSession()
        await account.invalidateSession(matching: oldSession.credentialIdentity)
        let signedOut = await account.isSignedIn
        XCTAssertFalse(signedOut)

        try await account.startSignIn(email: "marcus@example.com")
        try await account.completeSignIn(code: "123456")
        let signedIn = await account.isSignedIn
        XCTAssertTrue(signedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_D")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_2")

        await account.invalidateSession(matching: oldSession.credentialIdentity)

        let stillSignedIn = await account.isSignedIn
        XCTAssertTrue(stillSignedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_D")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_2")
    }
}
