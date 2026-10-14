import XCTest
@testable import Sentwise

/// Per-account Google token storage (item 104).
final class GmailAuthStoreTests: XCTestCase {

    private func makeStore() -> (GmailAuthStore, InMemorySecretStore) {
        let secrets = InMemorySecretStore()
        return (GmailAuthStore(secrets: secrets), secrets)
    }

    private func sampleToken(_ accessToken: String = "at") -> OAuthToken {
        OAuthToken(
            accessToken: accessToken,
            refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 2_000_000),
            scope: GoogleOAuth.mailScope,
            tokenType: "Bearer"
        )
    }

    func testTokenRoundTripUnderPerAccountKey() throws {
        let (store, secrets) = makeStore()
        try store.saveToken(sampleToken(), for: " Me@Gmail.com ")

        XCTAssertEqual(try store.loadToken(for: "me@gmail.com"), sampleToken())
        XCTAssertNotNil(try secrets.value(for: SecretKey(rawValue: "gmail.oauthToken.me@gmail.com")))
        XCTAssertNil(try secrets.value(for: .gmailToken), "the legacy single-account slot is never written")
    }

    func testAccountsAreIsolated() throws {
        let (store, _) = makeStore()
        try store.saveToken(sampleToken("a-token"), for: "a@gmail.com")
        try store.saveToken(sampleToken("b-token"), for: "b@gmail.com")

        try store.deleteToken(for: "a@gmail.com")

        XCTAssertFalse(store.hasToken(for: "a@gmail.com"))
        XCTAssertEqual(try store.loadToken(for: "b@gmail.com")?.accessToken, "b-token")
    }

    func testTokensWithoutIDTokenFieldStillDecode() throws {
        let (store, secrets) = makeStore()
        let json = #"{"accessToken":"at","refreshToken":"rt","expiresAt":0,"scope":"s","tokenType":"Bearer"}"#
        try secrets.set(json, for: .gmailOAuthToken(email: "me@gmail.com"))
        XCTAssertEqual(try store.loadToken(for: "me@gmail.com")?.accessToken, "at")
    }

    func testLogSafeIdentifierNeverIncludesTheEmail() {
        XCTAssertEqual(SecretKey.gmailOAuthToken(email: "me@gmail.com").logSafeIdentifier, "gmail.oauthToken")
    }
}
