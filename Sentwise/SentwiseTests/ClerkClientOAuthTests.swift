import XCTest
@testable import Sentwise

/// Unit tests for `ClerkClient`'s Google/OAuth sign-in start + completion
/// (item 59), driven against the shared fake Clerk transport.
final class ClerkClientOAuthTests: XCTestCase {

    private func client(_ transport: QueueClerkTransport) -> ClerkClient {
        ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: transport
        )
    }

    func testStartOAuthSignInReturnsHostedRedirectAndRotatedToken() async throws {
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","first_factor_verification":"#
                    + #"{"external_verification_redirect_url":"https://accounts.google.com/o/oauth2/auth?x=1"}}}"#,
                clientToken: "client_A"
            )
        ])

        let handle = try await client(transport).startOAuthSignIn(
            strategy: "oauth_google",
            redirectURL: "sentwise://oauth-callback",
            clientToken: ""
        )

        XCTAssertEqual(handle.signInId, "sia_1")
        XCTAssertEqual(handle.externalRedirectURL.absoluteString, "https://accounts.google.com/o/oauth2/auth?x=1")
        XCTAssertEqual(handle.clientToken, "client_A")

        let request = transport.requests[0]
        XCTAssertTrue(request.url.absoluteString.contains("/v1/client/sign_ins"))
        XCTAssertTrue(request.url.absoluteString.contains("_is_native=1"))
        XCTAssertEqual(request.form["strategy"], "oauth_google")
        XCTAssertEqual(request.form["redirect_url"], "sentwise://oauth-callback")
    }

    func testStartOAuthSignInThrowsWhenRedirectMissing() async {
        let transport = QueueClerkTransport([
            clerkReply(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_A")
        ])
        do {
            _ = try await client(transport).startOAuthSignIn(
                strategy: "oauth_google",
                redirectURL: "sentwise://oauth-callback",
                clientToken: ""
            )
            XCTFail("Expected malformedResponse")
        } catch ClerkError.malformedResponse(let message, let clientToken) {
            XCTAssertEqual(message, "external verification redirect url missing")
            XCTAssertEqual(clientToken, "client_A")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCompleteOAuthSignInReturnsSessionAndIdentifierWithNonce() async throws {
        let transport = QueueClerkTransport([
            clerkReply(
                #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_9","identifier":"marcus@example.com"}}"#,
                clientToken: "client_B"
            )
        ])

        let verified = try await client(transport).completeOAuthSignIn(
            signInId: "sia_1",
            rotatingTokenNonce: "nonce_xyz",
            clientToken: "client_A"
        )

        XCTAssertEqual(verified.sessionId, "sess_9")
        XCTAssertEqual(verified.identifier, "marcus@example.com")
        XCTAssertEqual(verified.clientToken, "client_B")

        let request = transport.requests[0]
        XCTAssertTrue(request.url.absoluteString.contains("/v1/client/sign_ins/sia_1"))
        XCTAssertTrue(request.url.absoluteString.contains("rotating_token_nonce=nonce_xyz"))
        XCTAssertEqual(request.method, "GET", "Clerk completes native OAuth by reloading the sign-in, not posting to it")
        XCTAssertEqual(request.headers["authorization"], "Bearer client_A")
    }

    func testCompleteOAuthSignInThrowsWhenNotComplete() async {
        let transport = QueueClerkTransport([
            clerkReply(#"{"response":{"id":"sia_1","status":"needs_identifier"}}"#, clientToken: "client_B")
        ])
        do {
            _ = try await client(transport).completeOAuthSignIn(
                signInId: "sia_1",
                rotatingTokenNonce: "nonce",
                clientToken: "client_A"
            )
            XCTFail("Expected notComplete")
        } catch ClerkError.notComplete(let status, _, let clientToken) {
            XCTAssertEqual(status, "needs_identifier")
            XCTAssertEqual(clientToken, "client_B")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
