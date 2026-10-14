import SentwiseMail
import XCTest
@testable import Sentwise

/// How token-endpoint failures are classified (item 104): Google outages and
/// throttling (5xx, 429) are transient and retried; a rejected grant
/// (400/401 `invalid_grant`) still asks the user to sign in again.
@MainActor
final class GoogleTokenEndpointFailureTests: XCTestCase {

    private let client = GoogleOAuthClientConfiguration(clientID: "1234-abc.apps.googleusercontent.com")

    private func refresh(status: Int, body: String) async -> Error? {
        let transport = FakeTransport(response: HTTPResponse(statusCode: status, body: Data(body.utf8)))
        do {
            _ = try await OAuthTokenService(transport: transport).refresh(refreshToken: "rt", client: client, now: Date())
            return nil
        } catch {
            return error
        }
    }

    func testOutagesAndThrottlingKeepTheirHTTPStatus() async {
        for status in [429, 500, 502, 503, 504] {
            let bare = await refresh(status: status, body: "<html>Service Unavailable</html>")
            XCTAssertEqual(bare as? OAuthError, .temporarilyUnavailable(httpStatus: status), "\(status)")
            let withBody = await refresh(status: status, body: #"{"error":"internal_failure"}"#)
            XCTAssertEqual(withBody as? OAuthError, .temporarilyUnavailable(httpStatus: status), "\(status) with error body")
        }
    }

    func testRejectedGrantsStayServerErrors() async {
        let badRequest = await refresh(status: 400, body: #"{"error":"invalid_grant"}"#)
        XCTAssertEqual(badRequest as? OAuthError, .server(code: "invalid_grant", description: nil))
        let unauthorized = await refresh(status: 401, body: #"{"error":"invalid_client"}"#)
        XCTAssertEqual(unauthorized as? OAuthError, .server(code: "invalid_client", description: nil))
    }

    // MARK: - Mail provider classification

    private func resolveExpiredToken(status: Int, body: String) async throws -> Error {
        let secrets = InMemorySecretStore()
        let store = GmailAuthStore(secrets: secrets)
        try store.saveToken(OAuthToken(
            accessToken: "stale", refreshToken: "rt", expiresAt: .distantPast,
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        ), for: "me@gmail.com")
        let transport = FakeTransport(response: HTTPResponse(statusCode: status, body: Data(body.utf8)))
        let auth = GoogleMailAuthService(coordinator: GmailAuthCoordinator(
            client: client, store: store, tokenService: OAuthTokenService(transport: transport)
        ))
        let provider = GoogleOAuthMailProvider(base: FakeAppMailProvider(result: .success(())), auth: auth)
        do {
            try await provider.verifyConnection(GoogleMailCredential.credentials(email: "me@gmail.com"))
        } catch {
            return error
        }
        XCTFail("expected the refresh to fail")
        return CancellationError()
    }

    func testTokenEndpoint503And429AreTransientSoTheWatcherRetries() async throws {
        for status in [503, 429] {
            let error = try await resolveExpiredToken(status: status, body: #"{"error":"backend_error"}"#)
            guard case .connectionFailed = error as? MailError else {
                XCTFail("HTTP \(status) should be a connection failure, got \(error)")
                continue
            }
            XCTAssertEqual(ResilienceClassifier.classify(error), .transient, "HTTP \(status)")
        }
    }

    func testInvalidGrantIsStillAnAuthenticationFailure() async throws {
        for status in [400, 401] {
            let error = try await resolveExpiredToken(status: status, body: #"{"error":"invalid_grant"}"#)
            XCTAssertEqual(error as? MailError, .authenticationFailed(GoogleMailCredential.reauthorizationDetail))
            XCTAssertEqual(ResilienceClassifier.classify(error), .authentication, "HTTP \(status)")
        }
    }
}
