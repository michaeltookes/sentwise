import XCTest
@testable import Sentwise

final class ManagedSignOutDurabilityTests: XCTestCase {

    private func service(_ transport: ClerkHTTPTransport, secrets: SecretStore) -> ManagedAccountService {
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        return ManagedAccountService(secrets: secrets, clerk: clerk)
    }

    func testSignOutSurfacesKeychainRemovalFailuresButInvalidatesCredentials() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        do {
            try await account.signOut()
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertTrue(error.didDurablySignOut)
            guard case ManagedAccountTestSecretError.removeDenied = error.underlying else {
                return XCTFail("Unexpected underlying error: \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
        XCTAssertEqual(try secrets.value(for: .managedCredentialsInvalidated), "1")
    }

    func testSignOutKeepsAccountSignedInWhenInvalidationMarkerAndCleanupBothFail() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnSetKeys = [.managedCredentialsInvalidated]
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        do {
            try await account.signOut()
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertFalse(error.didDurablySignOut)
            guard case ManagedAccountTestSecretError.removeDenied = error.underlying else {
                return XCTFail("Unexpected underlying error: \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedIn = await account.isSignedIn
        XCTAssertTrue(signedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
        XCTAssertNil(try secrets.value(for: .managedCredentialsInvalidated))
    }

    func testClientTokenRemovalDurablySignsOutAndKeepsSignInTokenSeparateFromStaleSession() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnSetKeys = [.managedCredentialsInvalidated]
        secrets.failOnRemoveKeys = [.managedSessionID]
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                clientToken: "client_A"
            ),
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B")
        ])
        let account = service(transport, secrets: secrets)

        do {
            try await account.signOut(revokeServerSession: false)
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertTrue(error.didDurablySignOut)
            guard case ManagedAccountTestSecretError.removeDenied = error.underlying else {
                return XCTFail("Unexpected underlying error: \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
        XCTAssertNil(try secrets.value(for: .managedCredentialsInvalidated))

        secrets.failOnRemoveKeys = []
        let relaunchedAccount = service(transport, secrets: secrets)
        try await relaunchedAccount.startSignIn(email: "marcus@example.com")

        XCTAssertEqual(transport.requests.first?.headers["authorization"], "Bearer ")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_B")
        XCTAssertNil(try secrets.value(for: .managedSessionID))
        XCTAssertNil(try secrets.value(for: .managedReauthenticationClientToken))
    }

    func testSignOutPreservesExistingInvalidationMarkerWhenCleanupFails() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X",
            .managedCredentialsInvalidated: "1"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        do {
            try await account.signOut()
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertTrue(error.didDurablySignOut)
            guard case ManagedAccountTestSecretError.removeDenied = error.underlying else {
                return XCTFail("Unexpected underlying error: \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
        XCTAssertEqual(try secrets.value(for: .managedCredentialsInvalidated), "1")
    }

    func testSignOutRetainsInvalidationMarkerAfterPartialCleanup() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedSessionID]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        do {
            try await account.signOut()
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertTrue(error.didDurablySignOut)
            guard case ManagedAccountTestSecretError.removeDenied = error.underlying else {
                return XCTFail("Unexpected underlying error: \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
        XCTAssertEqual(try secrets.value(for: .managedCredentialsInvalidated), "1")
    }

    func testSignOutSurfacesMarkerClearFailureAfterCredentialRemoval() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedCredentialsInvalidated]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        do {
            try await account.signOut()
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertTrue(error.didDurablySignOut)
            guard case ManagedAccountTestSecretError.removeDenied = error.underlying else {
                return XCTFail("Unexpected underlying error: \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedIn = await account.isSignedIn
        let invalidated = await account.areStoredCredentialsInvalidated
        XCTAssertFalse(signedIn)
        XCTAssertTrue(invalidated)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
        XCTAssertEqual(try secrets.value(for: .managedCredentialsInvalidated), "1")
    }

    func testSignOutTreatsObservedAbsentSessionAsDurableWhenDeleteFails() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X"
        ])
        secrets.failOnSetKeys = [.managedCredentialsInvalidated]
        secrets.failOnRemoveKeys = [.managedSessionID]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        do {
            try await account.signOut()
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertTrue(error.didDurablySignOut)
            guard case ManagedAccountTestSecretError.removeDenied = error.underlying else {
                return XCTFail("Unexpected underlying error: \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
        XCTAssertNil(try secrets.value(for: .managedCredentialsInvalidated))
    }

    func testSignOutPersistsInvalidationMarkerWhenCredentialReadFails() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnValueKeys = [.managedSessionID]
        secrets.failOnRemoveKeys = [.managedSessionID]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        do {
            try await account.signOut()
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertTrue(error.didDurablySignOut)
            guard case ManagedAccountTestSecretError.removeDenied = error.underlying else {
                return XCTFail("Unexpected underlying error: \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertEqual(secrets.storedValueIgnoringFailures(for: .managedSessionID), "sess_X")
        XCTAssertEqual(try secrets.value(for: .managedCredentialsInvalidated), "1")
    }

    func testSignOutCancelsServerRevocationWhenLocalCleanupIsNonDurable() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnSetKeys = [.managedCredentialsInvalidated]
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let transport = RecordingClerkTransport()
        let account = service(transport, secrets: secrets)

        do {
            try await account.signOut(revokeServerSession: true)
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertFalse(error.didDurablySignOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(transport.recordedURLs.isEmpty)
        let signedIn = await account.isSignedIn
        XCTAssertTrue(signedIn)
    }
}
final class ManagedSignOutRotationTests: XCTestCase {
    private func service(_ transport: ClerkHTTPTransport, secrets: SecretStore) -> ManagedAccountService {
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        return ManagedAccountService(secrets: secrets, clerk: clerk)
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

    func testPendingRevocationFollowsRetryRotationAfterUnpersistedToken() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnSetKeys = [.managedClientToken]
        let transport = MultiSuspendedClerkTransport()
        let firstMintStarted = expectation(description: "first mint request started")
        let secondMintStarted = expectation(description: "second mint request started")
        let revocationStarted = expectation(description: "revocation request started")
        transport.onRequest = { requestNumber in
            if requestNumber == 1 {
                firstMintStarted.fulfill()
            } else if requestNumber == 2 {
                secondMintStarted.fulfill()
            } else if requestNumber == 3 {
                revocationStarted.fulfill()
            }
        }
        let account = service(transport, secrets: secrets)

        let firstTokenTask = Task { try await account.currentSessionToken() }
        await fulfillment(of: [firstMintStarted], timeout: 1.0)
        transport.resumeNext(with: clerkReply(#"{"jwt":"stale.jwt"}"#, clientToken: "client_Y"))

        do {
            _ = try await firstTokenTask.value
            XCTFail("Expected token persistence failure")
        } catch ManagedAccountTestSecretError.setDenied {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let secondTokenTask = Task { try await account.currentSessionToken() }
        await fulfillment(of: [secondMintStarted], timeout: 1.0)
        XCTAssertEqual(transport.authorizationHeader(at: 1), "Bearer client_Y")

        try await account.signOut(revokeServerSession: true)
        XCTAssertEqual(transport.requestCount, 2)

        transport.resumeNext(with: clerkReply(#"{"jwt":"fresh.jwt"}"#, clientToken: "client_Z"))
        do {
            _ = try await secondTokenTask.value
            XCTFail("Expected managedNotSignedIn")
        } catch LLMError.managedNotSignedIn {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await fulfillment(of: [revocationStarted], timeout: 1.0)
        XCTAssertEqual(transport.url(at: 2)?.path, "/v1/client/sessions/sess_X/remove")
        XCTAssertEqual(transport.authorizationHeader(at: 2), "Bearer client_Z")
        transport.resumeNext(with: ClerkHTTPResponse(statusCode: 200, headers: [:], body: Data()))
    }

    func testNonDurableSignOutKeepsUnpersistedRotationForNextMint() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnSetKeys = [.managedClientToken]
        let transport = MultiSuspendedClerkTransport()
        let firstMintStarted = expectation(description: "first mint request started")
        let secondMintStarted = expectation(description: "second mint request started")
        transport.onRequest = { requestNumber in
            if requestNumber == 1 {
                firstMintStarted.fulfill()
            } else if requestNumber == 2 {
                secondMintStarted.fulfill()
            }
        }
        let account = service(transport, secrets: secrets)

        let firstTokenTask = Task { try await account.currentSessionToken() }
        await fulfillment(of: [firstMintStarted], timeout: 1.0)
        transport.resumeNext(with: clerkReply(#"{"jwt":"stale.jwt"}"#, clientToken: "client_Y"))

        do {
            _ = try await firstTokenTask.value
            XCTFail("Expected token persistence failure")
        } catch ManagedAccountTestSecretError.setDenied {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        secrets.failOnSetKeys = [.managedCredentialsInvalidated]
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        do {
            try await account.signOut(revokeServerSession: true)
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertFalse(error.didDurablySignOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requestCount, 1)

        secrets.failOnSetKeys = []
        secrets.failOnRemoveKeys = []
        let secondTokenTask = Task { try await account.currentSessionToken() }
        await fulfillment(of: [secondMintStarted], timeout: 1.0)
        XCTAssertEqual(transport.authorizationHeader(at: 1), "Bearer client_Y")
        transport.resumeNext(with: clerkReply(#"{"jwt":"fresh.jwt"}"#, clientToken: "client_Z"))

        let token = try await secondTokenTask.value
        XCTAssertEqual(token, "fresh.jwt")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_Z")
    }

    func testSignOutReportsNonDurableWhenCleanupAndPostCleanupReadsFail() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnSetKeys = [.managedCredentialsInvalidated]
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        secrets.failOnValueAfterRemoveAttemptKeys = [.managedClientToken, .managedSessionID]
        let account = service(QueueClerkTransport([]), secrets: secrets)

        do {
            try await account.signOut()
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertFalse(error.didDurablySignOut)
            guard case ManagedAccountTestSecretError.removeDenied = error.underlying else {
                return XCTFail("Unexpected underlying error: \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(secrets.storedValueIgnoringFailures(for: .managedClientToken), "client_X")
        XCTAssertEqual(secrets.storedValueIgnoringFailures(for: .managedSessionID), "sess_X")
        XCTAssertNil(try secrets.value(for: .managedCredentialsInvalidated))
    }

    func testSignOutInvalidatesCredentialsBeforeCleanupFailureAfterRevocation() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let transport = RecordingClerkTransport()
        let revoked = expectation(description: "server-side session revocation POST")
        transport.onPost = { url in
            if url.absoluteString.contains("/v1/client/sessions/sess_X/remove") {
                revoked.fulfill()
            }
        }
        let account = service(transport, secrets: secrets)

        do {
            try await account.signOut(revokeServerSession: true)
            XCTFail("Expected sign-out failure")
        } catch let error as ManagedAccountSignOutError {
            XCTAssertTrue(error.didDurablySignOut)
            guard case ManagedAccountTestSecretError.removeDenied = error.underlying else {
                return XCTFail("Unexpected underlying error: \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await fulfillment(of: [revoked], timeout: 1.0)
        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
        XCTAssertEqual(try secrets.value(for: .managedCredentialsInvalidated), "1")
    }
}
