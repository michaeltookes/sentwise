import Foundation

/// Static Google OAuth / Gmail constants.
enum GoogleOAuth {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Full IMAP/SMTP access, the only scope Google accepts for `XOAUTH2` mail
    /// sessions (item 104). Restricted: a public client needs Google's
    /// restricted-scope verification plus an annual CASA assessment
    /// (`docs/gmail-oauth.md`).
    static let mailScope = "https://mail.google.com/"

    /// Requested scopes: the mail scope plus `openid email`, which are
    /// non-sensitive and only let the app learn which address was authorized
    /// (from the ID token) so the user never has to type it.
    static let scopes = [mailScope, "openid", "email"]

    /// Scopes the granted token must carry for the connection to be usable.
    /// Google may grant `openid`/`email` under different spellings, so only the
    /// mail scope is enforced.
    static let requiredScopes = [mailScope]
}

/// The OAuth client Sentwise ships with (item 104): one Sentwise-owned Google
/// Cloud "Desktop app" client, configured per build — never committed.
///
/// The values come from the app's Info.plist, which expands the
/// `SENTWISE_GOOGLE_CLIENT_ID` / `SENTWISE_GOOGLE_CLIENT_SECRET` build settings
/// from `Sentwise/Config/GoogleOAuth.xcconfig` (and its git-ignored local
/// override). A build without a real client ID has the feature switched off:
/// `bundled()` returns nil and the UI offers only the app-password path.
///
/// The client secret of an installed-app client is not confidential (Google's
/// installed-app guidance; anything in a shipped binary is extractable) — it is
/// kept out of the repo only so forks and CI builds do not impersonate the
/// Sentwise client. PKCE is what protects the authorization code.
enum GoogleOAuthClientConfiguration {
    static let clientIDInfoKey = "SentwiseGoogleOAuthClientID"
    static let clientSecretInfoKey = "SentwiseGoogleOAuthClientSecret"
    static let clientIDSuffix = ".apps.googleusercontent.com"

    /// The bundled Google configuration, or nil when this build has no client.
    static func bundled(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> OAuthProviderConfiguration? {
        guard let rawID = infoDictionary?[clientIDInfoKey] as? String else { return nil }
        let clientID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableClientID(clientID) else { return nil }
        let rawSecret = infoDictionary?[clientSecretInfoKey] as? String
        let secret = rawSecret.flatMap { isUnexpandedOrPlaceholder($0) ? nil : $0 }
        return .google(clientID: clientID, clientSecret: secret)
    }

    /// A real Google OAuth client ID: non-empty, not an unexpanded build
    /// variable or the committed placeholder, and in Google's ID format.
    static func isUsableClientID(_ clientID: String) -> Bool {
        guard !clientID.isEmpty, !isUnexpandedOrPlaceholder(clientID) else { return false }
        return clientID.hasSuffix(clientIDSuffix) && clientID.count > clientIDSuffix.count
    }

    static func isUnexpandedOrPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || trimmed.contains("$(")
            || trimmed.uppercased().contains("PLACEHOLDER")
            || trimmed.uppercased().hasPrefix("YOUR_")
    }
}

/// An OAuth token set returned by Google's token endpoint.
struct OAuthToken: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    /// Absolute expiry time, computed from `expires_in` at fetch time.
    let expiresAt: Date
    let scope: String
    let tokenType: String
    /// The OpenID Connect ID token (code exchange only); carries the email.
    var idToken: String?

    init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        scope: String,
        tokenType: String,
        idToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
        self.idToken = idToken
    }

    /// Whether the access token is expired (or within `leeway` of expiring).
    func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }

    func missingScopes(from requiredScopes: [String]) -> [String] {
        let grantedScopes = Set(scope.split(separator: " ").map(String.init))
        return requiredScopes.filter { !grantedScopes.contains($0) }
    }
}

/// Reads the `email` claim from a Google ID token.
///
/// The token is received directly from Google's token endpoint over TLS in the
/// same exchange, so per Google's OpenID Connect guidance its signature does not
/// need to be re-verified to read claims. It is used only to learn which
/// mailbox the user authorized — never as an authentication assertion.
enum GoogleIDToken {
    private static func claims(_ idToken: String) -> [String: Any]? {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = Data(base64URLEncoded: String(segments[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }

    /// The signed-in mailbox address: `email`, or (Microsoft ID tokens) the
    /// `preferred_username` claim when no `email` claim is present.
    static func email(fromIDToken idToken: String) -> String? {
        guard let object = claims(idToken) else { return nil }
        let raw = (object["email"] as? String) ?? (object["preferred_username"] as? String)
        guard let email = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty, email.contains("@") else {
            return nil
        }
        if let verified = object["email_verified"] as? Bool, !verified { return nil }
        if let verified = object["email_verified"] as? String, verified.lowercased() != "true" { return nil }
        return email
    }

    /// The Entra tenant (`tid`) of a Microsoft ID token; nil for Google tokens.
    static func tenantID(fromIDToken idToken: String) -> String? {
        guard let tid = (claims(idToken)?["tid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tid.isEmpty else { return nil }
        return tid
    }
}

/// Errors surfaced by the OAuth flow.
enum OAuthError: Error, Equatable {
    /// The token endpoint returned an error (`error` / `error_description`).
    case server(code: String, description: String?)
    /// The response could not be decoded.
    case invalidResponse
    /// The `state` returned on the redirect did not match what we sent (CSRF guard).
    case stateMismatch
    /// The redirect carried an error instead of an authorization code.
    case authorizationDenied(String)
    /// No refresh token is available to refresh the session.
    case missingRefreshToken
    /// The browser did not return to the loopback listener in time.
    case redirectTimedOut
    /// Google returned a token that lacks one or more required Gmail scopes.
    case missingRequiredScopes([String])
    /// The token endpoint is overloaded or down (HTTP 5xx) or rate-limiting us
    /// (HTTP 429). Transient: the grant is still good, so callers retry later
    /// instead of asking the user to sign in again.
    case temporarilyUnavailable(httpStatus: Int)
    /// The organization requires an administrator to approve the app (Microsoft
    /// AADSTS65001, 90094, 90095, `consent_required`). `tenantID` is the Entra
    /// tenant when the response carried one; the admin note falls back to the
    /// address's domain. Not retryable: an administrator must act (item 31, T31-3).
    case adminConsentRequired(tenantID: String?)
    /// The stored grant can no longer be refreshed (`invalid_grant`,
    /// `interaction_required`, Microsoft AADSTS50173 and friends): the user
    /// must sign in again. Applies to Google `invalid_grant` too.
    case reauthenticationRequired

    /// Whether an HTTP status from the token endpoint means "retry later"
    /// rather than "this request or grant is bad".
    static func isTransientHTTPStatus(_ status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }
}
