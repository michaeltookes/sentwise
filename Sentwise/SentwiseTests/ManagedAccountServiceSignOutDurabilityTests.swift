import XCTest
@testable import Sentwise

/// Sign-out durability edge cases that should stay separate from the already
/// broad session-token suite.
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
