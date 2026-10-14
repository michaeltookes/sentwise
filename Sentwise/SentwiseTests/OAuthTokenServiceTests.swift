import XCTest
@testable import Sentwise

final class OAuthTokenServiceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let client = GoogleOAuthClientConfiguration(clientID: "cid.apps.googleusercontent.com", clientSecret: "secret")

    private func service(_ response: HTTPResponse) -> (OAuthTokenService, FakeTransport) {
        let transport = FakeTransport(response: response)
        return (OAuthTokenService(transport: transport), transport)
    }

    private func json(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(string.utf8))
    }

    func testExchangeParsesTokenAndComputesExpiry() async throws {
        let (service, transport) = service(json("""
        {"access_token":"at","refresh_token":"rt","expires_in":3599,
         "scope":"s","token_type":"Bearer"}
        """))

        let token = try await service.exchange(
            code: "auth-code",
            verifier: "verifier",
            client: client,
            redirectURI: "http://127.0.0.1:9000",
            requestedScopes: GoogleOAuth.scopes,
            now: now
        )

        XCTAssertEqual(token.accessToken, "at")
        XCTAssertEqual(token.refreshToken, "rt")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(3599))
        XCTAssertEqual(transport.lastURL, GoogleOAuth.tokenEndpoint)
        XCTAssertEqual(transport.lastFields["grant_type"], "authorization_code")
        XCTAssertEqual(transport.lastFields["code"], "auth-code")
        XCTAssertEqual(transport.lastFields["code_verifier"], "verifier")
        XCTAssertEqual(transport.lastFields["redirect_uri"], "http://127.0.0.1:9000")
        XCTAssertEqual(transport.lastFields["client_secret"], "secret")
        XCTAssertEqual(transport.lastFields["client_id"], "cid.apps.googleusercontent.com")
    }

    func testExchangeKeepsIDTokenAndOmitsSecretWhenClientHasNone() async throws {
        let (service, transport) = service(json("""
        {"access_token":"at","refresh_token":"rt","expires_in":3599,
         "scope":"https://mail.google.com/ openid","token_type":"Bearer","id_token":"a.b.c"}
        """))

        let token = try await service.exchange(
            code: "c", verifier: "v",
            client: GoogleOAuthClientConfiguration(clientID: "cid.apps.googleusercontent.com", clientSecret: "  "),
            redirectURI: "http://127.0.0.1:9000", requestedScopes: GoogleOAuth.scopes, now: now
        )

        XCTAssertEqual(token.idToken, "a.b.c")
        XCTAssertNil(transport.lastFields["client_secret"], "an empty secret is never sent")
    }

    func testExchangeKeepsRequestedScopesOnlyWhenResponseOmitsScope() async throws {
        let requestedScopes = ["openid", "email"]
        for responseScope in [nil, "openid", ""] as [String?] {
            let scopeField = responseScope.map { ",\"scope\":\"\($0)\"" } ?? ""
            let (service, _) = service(json("""
            {"access_token":"at","refresh_token":"rt","expires_in":3600\(scopeField)}
            """))

            let token = try await service.exchange(
                code: "c", verifier: "v", client: client,
                redirectURI: "http://127.0.0.1:9000", requestedScopes: requestedScopes, now: now
            )

            XCTAssertEqual(token.scope, responseScope ?? requestedScopes.joined(separator: " "))
        }
    }

    func testRevokePostsTokenToRevocationEndpoint() async throws {
        let (service, transport) = service(json("", status: 200))
        try await service.revoke(token: "rt")
        XCTAssertEqual(transport.lastURL, GoogleOAuth.revocationEndpoint)
        XCTAssertEqual(transport.lastFields, ["token": "rt"])
    }

    func testRefreshCarriesForwardExistingRefreshToken() async throws {
        // Google omits refresh_token on refresh responses.
        let (service, transport) = service(json("""
        {"access_token":"new-at","expires_in":3600,"scope":"s","token_type":"Bearer"}
        """))

        let token = try await service.refresh(
            refreshToken: "existing-rt",
            client: client,
            now: now
        )

        XCTAssertEqual(token.accessToken, "new-at")
        XCTAssertEqual(token.refreshToken, "existing-rt")
        XCTAssertEqual(transport.lastFields["grant_type"], "refresh_token")
        XCTAssertEqual(transport.lastFields["refresh_token"], "existing-rt")
    }

    func testRefreshKeepsGrantedScopeOnlyWhenResponseOmitsIt() async throws {
        for responseScope in [nil, "openid", ""] as [String?] {
            let scopeField = responseScope.map { ",\"scope\":\"\($0)\"" } ?? ""
            let (service, _) = service(json("""
            {"access_token":"new-at","expires_in":3600\(scopeField)}
            """))

            let token = try await service.refresh(
                refreshToken: "rt", grantedScope: GoogleOAuth.mailScope, client: client, now: now
            )

            XCTAssertEqual(token.scope, responseScope ?? GoogleOAuth.mailScope)
        }
    }

    func testServerErrorIsSurfaced() async {
        let (service, _) = service(json("""
        {"error":"invalid_grant","error_description":"Token has been expired or revoked."}
        """, status: 400))

        do {
            _ = try await service.refresh(refreshToken: "rt", client: client, now: now)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(
                error as? OAuthError,
                .server(code: "invalid_grant", description: "Token has been expired or revoked.")
            )
        }
    }

    func testMalformedSuccessBodyThrowsInvalidResponse() async {
        let (service, _) = service(json("{not json", status: 200))
        do {
            _ = try await service.exchange(
                code: "c", verifier: "v", client: client,
                redirectURI: "uri", requestedScopes: GoogleOAuth.scopes, now: now
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? OAuthError, .invalidResponse)
        }
    }
}

/// A fake `HTTPTransport` returning a canned response and recording the request.
/// Queued `responses` are served first (in order), then `response` repeats.
final class FakeTransport: HTTPTransport {
    var response: HTTPResponse
    var responses: [HTTPResponse] = []
    var error: Error?
    private(set) var lastURL: URL?
    private(set) var lastFields: [String: String] = [:]
    private(set) var requests: [(url: URL, fields: [String: String])] = []

    init(response: HTTPResponse) {
        self.response = response
    }

    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        lastURL = url
        lastFields = fields
        requests.append((url, fields))
        if let error { throw error }
        return responses.isEmpty ? response : responses.removeFirst()
    }
}
