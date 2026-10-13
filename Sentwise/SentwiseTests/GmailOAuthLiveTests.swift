import SentwiseMail
import XCTest
@testable import Sentwise

/// Live verification of the "Sign in with Google" mail path (item 104): refresh
/// a real Google grant for the bundled client, then authenticate to Gmail IMAP
/// with XOAUTH2. Read-only — no message is sent or changed.
///
/// **Credential-gated:** SKIPS unless every variable below is set, so it never
/// runs by default (CI, developer machines, the hosted unit-test run):
///
///   - `SENTWISE_LIVE_GOOGLE_OAUTH_EMAIL`          — the Gmail/Workspace address
///   - `SENTWISE_LIVE_GOOGLE_OAUTH_CLIENT_ID`      — the Sentwise Desktop client ID
///   - `SENTWISE_LIVE_GOOGLE_OAUTH_CLIENT_SECRET`  — its client secret (optional)
///   - `SENTWISE_LIVE_GOOGLE_OAUTH_REFRESH_TOKEN`  — a refresh token for that
///     address with the `https://mail.google.com/` scope (from one manual
///     sign-in; see `docs/gmail-oauth.md`)
///
/// Under `xcodebuild test` they need the `TEST_RUNNER_` prefix
/// (`docs/live-verification.md`). Tokens live only in memory here; nothing is
/// written to any Keychain.
@MainActor
final class GmailOAuthLiveTests: XCTestCase {

    func testRefreshedGoogleTokenAuthenticatesGmailIMAPWithXOAuth2() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SENTWISE_LIVE_GOOGLE_OAUTH_EMAIL"], !email.isEmpty,
              let clientID = env["SENTWISE_LIVE_GOOGLE_OAUTH_CLIENT_ID"], !clientID.isEmpty,
              let refreshToken = env["SENTWISE_LIVE_GOOGLE_OAUTH_REFRESH_TOKEN"], !refreshToken.isEmpty else {
            throw XCTSkip(
                "Set SENTWISE_LIVE_GOOGLE_OAUTH_EMAIL, _CLIENT_ID, and _REFRESH_TOKEN to run the Google OAuth live test."
            )
        }
        let client = GoogleOAuthClientConfiguration(
            clientID: clientID,
            clientSecret: env["SENTWISE_LIVE_GOOGLE_OAUTH_CLIENT_SECRET"]
        )

        let token = try await OAuthTokenService(transport: URLSessionTransport())
            .refresh(refreshToken: refreshToken, client: client, now: Date())
        XCTAssertTrue(token.missingScopes(from: GoogleOAuth.requiredScopes).isEmpty, "grant lacks the mail scope")

        var credentials = GoogleMailCredential.credentials(email: email)
        credentials.oauthAccessToken = token.accessToken
        try await LiveMailProvider.imapProvider().verifyConnection(credentials)

        let recent = try await LiveMailProvider.imapProvider().fetchRecentMessages(credentials, mailbox: .inbox, limit: 1)
        XCTAssertLessThanOrEqual(recent.count, 1)
    }
}
