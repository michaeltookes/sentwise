import Foundation

/// Builds the Google OAuth authorization URL for the PKCE desktop/loopback flow.
enum OAuthAuthorizationURL {
    /// The URL for a provider configuration (endpoint, scopes and extra
    /// parameters all come from it).
    static func make(
        configuration: OAuthProviderConfiguration,
        redirectURI: String,
        pkce: PKCE,
        state: String,
        loginHint: String? = nil
    ) -> URL {
        make(
            endpoint: configuration.authorizationEndpoint,
            clientID: configuration.clientID,
            redirectURI: redirectURI,
            scopes: configuration.scopes,
            pkce: pkce,
            state: state,
            loginHint: loginHint,
            extraParameters: configuration.extraAuthorizationParameters
        )
    }

    static func make(
        endpoint: URL = GoogleOAuth.authorizationEndpoint,
        clientID: String,
        redirectURI: String,
        scopes: [String],
        pkce: PKCE,
        state: String,
        loginHint: String? = nil,
        extraParameters: [(name: String, value: String)] = [("access_type", "offline"), ("prompt", "consent")]
    ) -> URL {
        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )!

        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state)
        ] + extraParameters.map { URLQueryItem(name: $0.name, value: $0.value) }
        if let loginHint {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        }

        components.queryItems = items
        return components.url!
    }
}
