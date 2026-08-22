import Foundation

/// Parses an incoming `sentwise://` deep link into a recognized callback (item 59).
///
/// Two flows hand control back to the app through the custom scheme:
/// - Clerk Google sign-in → `sentwise://oauth-callback?rotating_token_nonce=…`
/// - OpenRouter key provisioning → `sentwise://openrouter-callback?code=…`
///
/// Anything else — a foreign scheme, an unknown host, or a missing required
/// parameter — is rejected (`nil`) so a stray or malicious URL can never drive
/// account auth or key exchange.
enum SentwiseURLCallback: Equatable {
    /// Clerk OAuth redirect carrying the rotating-token nonce to complete sign-in.
    case managedOAuth(nonce: String)
    /// OpenRouter redirect carrying the authorization code to exchange for a key.
    case openRouter(code: String)

    static let scheme = "sentwise"
    static let managedOAuthHost = "oauth-callback"
    static let openRouterHost = "openrouter-callback"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // The authority is the host for `scheme://host?…`, but a `scheme:path`
        // form (no `//`) surfaces the first path segment instead — accept either.
        let host = (url.host ?? components?.path.split(separator: "/").first.map(String.init))?.lowercased()
        let items = components?.queryItems ?? []

        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value, !raw.isEmpty else { return nil }
            return raw
        }

        switch host {
        case Self.managedOAuthHost:
            guard let nonce = value("rotating_token_nonce") else { return nil }
            self = .managedOAuth(nonce: nonce)
        case Self.openRouterHost:
            guard let code = value("code") else { return nil }
            self = .openRouter(code: code)
        default:
            return nil
        }
    }
}
