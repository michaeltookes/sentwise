import XCTest
@testable import Sentwise

/// Item 31 / T31-2: the Microsoft provider configuration, and its clean
/// "not configured" state while no Entra client id exists.
final class MicrosoftOAuthConfigurationTests: XCTestCase {

    private let key = MicrosoftOAuthClientConfiguration.clientIDInfoKey
    private let sampleGUID = "11111111-2222-3333-4444-555555555555"

    func testEmptyUnexpandedOrMissingClientIDMeansNotConfigured() {
        XCTAssertEqual(key, "SentwiseMicrosoftOAuthClientID")
        XCTAssertNil(MicrosoftOAuthClientConfiguration.bundled(infoDictionary: nil))
        XCTAssertNil(MicrosoftOAuthClientConfiguration.bundled(infoDictionary: [:]))
        XCTAssertNil(MicrosoftOAuthClientConfiguration.bundled(infoDictionary: [key: ""]))
        XCTAssertNil(MicrosoftOAuthClientConfiguration.bundled(infoDictionary: [key: "   "]))
        XCTAssertNil(MicrosoftOAuthClientConfiguration.bundled(infoDictionary: [key: "$(SENTWISE_MICROSOFT_CLIENT_ID)"]))
        XCTAssertNil(MicrosoftOAuthClientConfiguration.bundled(infoDictionary: [key: "YOUR_ENTRA_APPLICATION_CLIENT_ID"]))
        XCTAssertNil(MicrosoftOAuthClientConfiguration.bundled(infoDictionary: [key: "not-a-guid"]))
        XCTAssertNil(MicrosoftOAuthClientConfiguration.bundled(infoDictionary: [key: 42]))
    }

    func testGUIDClientIDIsConfiguredAndTrimmed() throws {
        let configuration = try XCTUnwrap(
            MicrosoftOAuthClientConfiguration.bundled(infoDictionary: [key: " \(sampleGUID) "])
        )
        XCTAssertEqual(configuration.id, .microsoft)
        XCTAssertEqual(configuration.clientID, sampleGUID)
    }

    func testMicrosoftConfigurationUsesCommonAuthorityNoSecretAndLocalhostRedirect() {
        let microsoft = OAuthProviderConfiguration.microsoft(clientID: sampleGUID)
        XCTAssertEqual(
            microsoft.authorizationEndpoint.absoluteString,
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        )
        XCTAssertEqual(
            microsoft.tokenEndpoint.absoluteString,
            "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        )
        XCTAssertNil(microsoft.clientSecret)
        XCTAssertNil(microsoft.revocationEndpoint)
        XCTAssertEqual(microsoft.redirectURI(forPort: 4242), "http://localhost:4242")
    }

    func testMicrosoftScopesAreResourceQualifiedAndBothMailScopesRequired() {
        let microsoft = OAuthProviderConfiguration.microsoft(clientID: sampleGUID)
        XCTAssertEqual(microsoft.scopes, [
            "https://outlook.office.com/IMAP.AccessAsUser.All",
            "https://outlook.office.com/SMTP.Send",
            "offline_access", "openid", "profile", "email"
        ])
        XCTAssertEqual(microsoft.requiredGrantedScopes, [
            "https://outlook.office.com/IMAP.AccessAsUser.All",
            "https://outlook.office.com/SMTP.Send"
        ])
        let imapOnly = OAuthToken(
            accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 2_000_000),
            scope: "https://outlook.office.com/IMAP.AccessAsUser.All openid", tokenType: "Bearer"
        )
        XCTAssertEqual(
            imapOnly.missingScopes(from: microsoft.requiredGrantedScopes),
            ["https://outlook.office.com/SMTP.Send"]
        )
    }

    func testMicrosoftTokensLiveInTheirOwnKeychainNamespace() {
        let microsoft = OAuthProviderConfiguration.microsoft(clientID: sampleGUID)
        let google = OAuthProviderConfiguration.google(clientID: "cid.apps.googleusercontent.com")
        XCTAssertEqual(microsoft.keychainPrefix, "microsoft")
        XCTAssertEqual(google.keychainPrefix, "gmail")
        XCTAssertNotEqual(microsoft.credentialMarker, google.credentialMarker)
        XCTAssertEqual(microsoft.credentialMarker, "sentwise-microsoft-oauth:v1")
    }

    func testBundledGoogleConfigurationIsUnaffectedByMicrosoftSupport() throws {
        let google = try XCTUnwrap(GoogleOAuthClientConfiguration.bundled(
            infoDictionary: [GoogleOAuthClientConfiguration.clientIDInfoKey: "cid.apps.googleusercontent.com"]
        ))
        XCTAssertEqual(google.id, .google)
        XCTAssertEqual(google.redirectHost, "127.0.0.1")
        XCTAssertEqual(google.keychainPrefix, "gmail")
    }
}
