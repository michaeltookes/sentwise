import Foundation

/// Which OAuth identity provider a configuration (and its stored tokens) belongs to.
enum OAuthProviderID: String, Equatable, Sendable {
    case google
}

/// Everything the OAuth coordinator, token service, token store and mail-provider
/// wrapper need to know about one provider (sign-in-first architecture 4.1), so
/// they carry no Google-specific constants. `google(clientID:clientSecret:)`
/// reproduces today's behaviour exactly: the Keychain prefix stays `gmail`, so
/// existing signed-in accounts keep working with no migration.
struct OAuthProviderConfiguration: Equatable, Sendable {
    let id: OAuthProviderID
    let clientID: String
    /// Present only for clients that require it at the token endpoint (Google
    /// "Desktop app"); a provider without one never sends the field.
    let clientSecret: String?
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    /// Nil when the provider has no revocation endpoint.
    let revocationEndpoint: URL?
    let scopes: [String]
    let requiredGrantedScopes: [String]
    /// Extra query items on the authorization request, after the common ones.
    let extraAuthorizationParameters: [(name: String, value: String)]
    /// Host in the loopback redirect URI (`http://<host>:<port>`).
    let redirectHost: String
    /// First component of every per-account Keychain key for this provider.
    let keychainPrefix: String
    /// The non-secret marker stored in place of an app password for a mailbox
    /// signed in through this provider.
    let credentialMarker: String

    init(
        id: OAuthProviderID,
        clientID: String,
        clientSecret: String? = nil,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        revocationEndpoint: URL?,
        scopes: [String],
        requiredGrantedScopes: [String],
        extraAuthorizationParameters: [(name: String, value: String)] = [],
        redirectHost: String,
        keychainPrefix: String,
        credentialMarker: String
    ) {
        self.id = id
        self.clientID = clientID
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = (secret?.isEmpty ?? true) ? nil : secret
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.scopes = scopes
        self.requiredGrantedScopes = requiredGrantedScopes
        self.extraAuthorizationParameters = extraAuthorizationParameters
        self.redirectHost = redirectHost
        self.keychainPrefix = keychainPrefix
        self.credentialMarker = credentialMarker
    }

    static let googleKeychainPrefix = "gmail"

    /// The loopback redirect URI for `port`.
    func redirectURI(forPort port: UInt16) -> String {
        "http://\(redirectHost):\(port)"
    }

    /// Sentwise's Google configuration: today's endpoints, scopes, redirect
    /// host, Keychain prefix (`gmail`) and credential marker.
    static func google(clientID: String, clientSecret: String? = nil) -> Self {
        Self(
            id: .google,
            clientID: clientID,
            clientSecret: clientSecret,
            authorizationEndpoint: GoogleOAuth.authorizationEndpoint,
            tokenEndpoint: GoogleOAuth.tokenEndpoint,
            revocationEndpoint: GoogleOAuth.revocationEndpoint,
            scopes: GoogleOAuth.scopes,
            requiredGrantedScopes: GoogleOAuth.requiredScopes,
            // Request a refresh token and force the consent screen so one is issued.
            extraAuthorizationParameters: [("access_type", "offline"), ("prompt", "consent")],
            redirectHost: "127.0.0.1",
            keychainPrefix: googleKeychainPrefix,
            credentialMarker: GoogleMailCredential.marker
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.clientID == rhs.clientID && lhs.clientSecret == rhs.clientSecret
            && lhs.authorizationEndpoint == rhs.authorizationEndpoint && lhs.tokenEndpoint == rhs.tokenEndpoint
            && lhs.revocationEndpoint == rhs.revocationEndpoint && lhs.scopes == rhs.scopes
            && lhs.requiredGrantedScopes == rhs.requiredGrantedScopes
            && lhs.extraAuthorizationParameters.map { [$0.name, $0.value] }
                == rhs.extraAuthorizationParameters.map { [$0.name, $0.value] }
            && lhs.redirectHost == rhs.redirectHost && lhs.keychainPrefix == rhs.keychainPrefix
            && lhs.credentialMarker == rhs.credentialMarker
    }
}
