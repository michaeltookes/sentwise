import XCTest
@testable import Sentwise

/// Item 31 / T31-1: the provider-neutral OAuth configuration reproduces
/// today's Google behaviour and namespaces a second provider separately.
final class OAuthProviderConfigurationTests: XCTestCase {

    private let google = OAuthProviderConfiguration.google(clientID: "cid.apps.googleusercontent.com", clientSecret: "s")

    private func sampleToken() -> OAuthToken {
        OAuthToken(
            accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 2_000_000),
            scope: GoogleOAuth.mailScope, tokenType: "Bearer"
        )
    }

    func testGoogleConfigurationKeepsTodaysEndpointsScopesAndRedirect() {
        XCTAssertEqual(google.id, .google)
        XCTAssertEqual(google.authorizationEndpoint.absoluteString, "https://accounts.google.com/o/oauth2/v2/auth")
        XCTAssertEqual(google.tokenEndpoint.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(google.revocationEndpoint?.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(google.scopes, ["https://mail.google.com/", "openid", "email"])
        XCTAssertEqual(google.requiredGrantedScopes, ["https://mail.google.com/"])
        XCTAssertEqual(google.redirectURI(forPort: 9999), LoopbackRedirectListener.redirectURI(forPort: 9999))
        XCTAssertEqual(google.redirectURI(forPort: 9999), "http://127.0.0.1:9999")
        XCTAssertEqual(google.credentialMarker, "sentwise-google-oauth:v1")
        XCTAssertEqual(google.clientSecret, "s")
    }

    func testGoogleAuthorizationURLStillAsksForOfflineAccessAndConsent() {
        let url = OAuthAuthorizationURL.make(
            configuration: google, redirectURI: "http://127.0.0.1:5000",
            pkce: PKCE(verifier: "v", challenge: "c"), state: "st", loginHint: "me@gmail.com"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = items.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(query["scope"], "https://mail.google.com/ openid email")
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["prompt"], "consent")
        XCTAssertEqual(query["login_hint"], "me@gmail.com")
        XCTAssertEqual(query["client_id"], "cid.apps.googleusercontent.com")
    }

    func testGoogleKeychainKeysAreTheExistingGmailKeys() throws {
        XCTAssertEqual(google.keychainPrefix, "gmail")
        let secrets = InMemorySecretStore()
        let store = GmailAuthStore(secrets: secrets, configuration: google)
        try store.saveToken(sampleToken(), for: " Me@Gmail.com ")
        XCTAssertNotNil(try secrets.value(for: SecretKey(rawValue: "gmail.oauthToken.me@gmail.com")))
        XCTAssertEqual(SecretKey.gmailOAuthToken(email: "me@gmail.com").rawValue, "gmail.oauthToken.me@gmail.com")
        XCTAssertEqual(
            SecretKey.oauthToken(keychainPrefix: "gmail", email: "me@gmail.com"),
            SecretKey.gmailOAuthToken(email: "me@gmail.com")
        )
    }

    func testSecondConfigurationStoresUnderSeparateKeys() throws {
        let secrets = InMemorySecretStore()
        let googleStore = GmailAuthStore(secrets: secrets, configuration: google)
        let otherStore = GmailAuthStore(secrets: secrets, keychainPrefix: "other")

        try googleStore.saveToken(sampleToken(), for: "me@example.com")
        XCTAssertNil(try otherStore.loadToken(for: "me@example.com"), "another prefix never sees Google's token")
        XCTAssertFalse(otherStore.hasToken(for: "me@example.com"))

        try otherStore.saveToken(sampleToken(), for: "me@example.com")
        XCTAssertNotNil(try secrets.value(for: SecretKey(rawValue: "other.oauthToken.me@example.com")))
        try otherStore.deleteToken(for: "me@example.com")
        XCTAssertTrue(googleStore.hasToken(for: "me@example.com"), "deleting one provider's token leaves the other's")
    }

    func testProviderWithoutRevocationEndpointSendsNothing() async throws {
        let noRevoke = OAuthProviderConfiguration(
            id: .google, clientID: "c",
            authorizationEndpoint: google.authorizationEndpoint, tokenEndpoint: google.tokenEndpoint,
            revocationEndpoint: nil, scopes: ["a"], requiredGrantedScopes: ["a"],
            redirectHost: "localhost", keychainPrefix: "other", credentialMarker: "m"
        )
        let transport = FakeTransport(response: HTTPResponse(statusCode: 200, body: Data()))
        try await OAuthTokenService(transport: transport).revoke(token: "rt", client: noRevoke)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(noRevoke.redirectURI(forPort: 1), "http://localhost:1")
    }
}
