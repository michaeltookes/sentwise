import XCTest
@testable import Sentwise

final class ManagedSignOutAuthFailureRotationTests: XCTestCase {
    private func service(_ transport: ClerkHTTPTransport, secrets: SecretStore) -> ManagedAccountService {
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
        return ManagedAccountService(secrets: secrets, clerk: clerk)
    }

    func testPendingRevocationUsesRotatedClientTokenFromStoredAuthFailure() async throws {
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

        try await account.signOut(revokeServerSession: true)
        XCTAssertEqual(transport.requestCount, 1)

        transport.resumeNext(with: clerkReply(
            #"{"errors":[{"message":"expired"}]}"#,
            status: 401,
            clientToken: "client_Y"
        ))
        do {
            _ = try await tokenTask.value
            XCTFail("Expected managedNotSignedIn")
        } catch LLMError.managedNotSignedIn {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await fulfillment(of: [revocationStarted], timeout: 1.0)
        XCTAssertEqual(transport.url(at: 1)?.path, "/v1/client/sessions/sess_X/remove")
        XCTAssertEqual(transport.authorizationHeader(at: 1), "Bearer client_Y")
        transport.resumeNext(with: ClerkHTTPResponse(statusCode: 200, headers: [:], body: Data()))
    }
}
