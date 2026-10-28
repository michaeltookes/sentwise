import Foundation

/// Persists each Google-connected mailbox's OAuth token set (item 104) in a
/// `SecretStore` — the Keychain in production, the isolated test service under
/// test (item 115), or memory in unit tests. Everything here is a secret, so
/// nothing is written to the plaintext settings file.
///
/// Tokens are keyed per account (`SecretKey.gmailOAuthToken(email:)`), mirroring
/// the per-account app-password slots (item 48), so several Google accounts can
/// be connected side by side and removing one deletes exactly its token.
final class GmailAuthStore {

    private let secrets: SecretStore
    private let keychainPrefix: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// `keychainPrefix` namespaces the provider's tokens; the default is
    /// Google's `gmail`, so existing signed-in accounts keep their keys.
    init(
        secrets: SecretStore = KeychainStore.shared,
        keychainPrefix: String = OAuthProviderConfiguration.googleKeychainPrefix
    ) {
        self.secrets = secrets
        self.keychainPrefix = keychainPrefix
    }

    convenience init(secrets: SecretStore = KeychainStore.shared, configuration: OAuthProviderConfiguration) {
        self.init(secrets: secrets, keychainPrefix: configuration.keychainPrefix)
    }

    private func key(for email: String) -> SecretKey {
        .oauthToken(keychainPrefix: keychainPrefix, email: email)
    }

    func saveToken(_ token: OAuthToken, for email: String) throws {
        let data = try encoder.encode(token)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OAuthError.invalidResponse
        }
        try secrets.set(json, for: key(for: email))
    }

    func loadToken(for email: String) throws -> OAuthToken? {
        guard let json = try secrets.value(for: key(for: email)),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(OAuthToken.self, from: data)
    }

    func deleteToken(for email: String) throws {
        try secrets.remove(key(for: email))
    }

    /// Whether a token is stored for `email` (i.e. it is Google-connected).
    func hasToken(for email: String) -> Bool {
        let token = (try? loadToken(for: email)) ?? nil
        return token != nil
    }
}
