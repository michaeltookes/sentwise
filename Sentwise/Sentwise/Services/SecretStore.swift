import Foundation

/// A typed key identifying a secret in a `SecretStore`.
///
/// Using a `RawRepresentable` struct (rather than an enum) lets us define
/// stable well-known keys *and* derive per-provider keys at runtime.
struct SecretKey: RawRepresentable, Hashable {
    let rawValue: String

    // MARK: Well-known keys

    /// The Gmail OAuth token set (access + refresh + expiry), stored as JSON.
    /// (OAuth path is parked; kept for a future bundled-client revival.)
    static let gmailToken = SecretKey(rawValue: "gmail.token")
    /// The legacy single-account mailbox app password slot. Superseded by the
    /// per-account key below (item 48); kept only so the v10→v11 migration can
    /// read the old secret before moving it, and as a read-fallback until every
    /// install has migrated. New writes always use `mailAppPassword(email:)`.
    static let mailAppPassword = SecretKey(rawValue: "mail.appPassword")

    /// The app password for a specific saved mail account (item 48), keyed by the
    /// account's normalized email so each account's secret is a distinct Keychain
    /// item. Mirrors the per-provider `llmAPIKey(provider:)` pattern, and uses the
    /// same normalization as `SavedMailAccount.id` so keys line up with the list.
    static func mailAppPassword(email: String) -> SecretKey {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SecretKey(rawValue: "mail.appPassword.\(normalized)")
    }
    /// The user-supplied Google Cloud OAuth client ID (BYO credentials).
    static let googleClientID = SecretKey(rawValue: "google.clientID")
    /// The user-supplied Google Cloud OAuth client secret (BYO credentials).
    static let googleClientSecret = SecretKey(rawValue: "google.clientSecret")

    /// The API key for a specific LLM provider (e.g. `"anthropic"`, `"openai"`).
    static func llmAPIKey(provider: String) -> SecretKey {
        SecretKey(rawValue: "llm.\(provider).apiKey")
    }

    /// The Clerk device/client token for the managed-inference account (56a). This
    /// long-lived, rotating token authenticates Frontend-API calls and lets the
    /// app mint fresh session tokens without re-signing-in.
    static let managedClientToken = SecretKey(rawValue: "managed.clientToken")
    /// The Clerk session id for the managed-inference account (56a). Combined with
    /// the client token, it mints the short-lived session JWTs the proxy verifies.
    static let managedSessionID = SecretKey(rawValue: "managed.sessionID")
    /// Marker that the managed credentials were rejected by Clerk or the proxy.
    /// Kept separate from the credentials so a failed Keychain cleanup cannot make
    /// an invalid pair look signed in again on the next launch.
    static let managedCredentialsInvalidated = SecretKey(rawValue: "managed.credentialsInvalidated")
    /// A fresh Clerk client token recovered while credentials are invalidated.
    /// Kept apart from the rejected stored session so reauthentication retries can
    /// echo Clerk's latest rotation without reviving the stale credential pair.
    static let managedReauthenticationClientToken = SecretKey(rawValue: "managed.reauthenticationClientToken")
    /// The transient Clerk OAuth sign-in id for a browser-based managed-account
    /// sign-in. Stored so a redirect that arrives after an app relaunch can still
    /// finish the same Clerk flow.
    static let managedOAuthSignInID = SecretKey(rawValue: "managed.oauthSignInID")

    /// The transient PKCE code verifier for an in-progress OpenRouter one-click
    /// key provisioning (item 59). Written when the browser hand-off starts and
    /// read+removed when the `sentwise://openrouter-callback` code comes back.
    static let openRouterPKCEVerifier = SecretKey(rawValue: "openRouter.pkceVerifier")
    /// The OpenRouter-provisioned OpenAI-compatible API key. Kept separate from the
    /// generic OpenAI-compatible slot so one-click setup never overwrites a manual
    /// OpenAI or gateway credential.
    static let openRouterAPIKey = SecretKey(rawValue: "llm.openRouter.apiKey")
}

/// Secure storage for sensitive strings — OAuth tokens, API keys, client secrets.
///
/// Implemented by `KeychainStore` in production and `InMemorySecretStore` in
/// tests/previews. Secrets never touch the plaintext settings file; everything
/// sensitive goes through here. This is the backbone of the local-first privacy
/// promise.
protocol SecretStore {
    /// Stores `value` for `key`, replacing any existing value.
    func set(_ value: String, for key: SecretKey) throws
    /// Returns the stored value for `key`, or `nil` if absent.
    func value(for key: SecretKey) throws -> String?
    /// Removes the value for `key`. No-op if absent.
    func remove(_ key: SecretKey) throws
    /// Removes every secret owned by this store (used on full disconnect/reset).
    func removeAll() throws
}

extension SecretStore {
    /// Whether a non-empty value exists for `key`.
    func hasValue(for key: SecretKey) -> Bool {
        let stored = (try? value(for: key)) ?? nil
        return stored?.isEmpty == false
    }
}

/// A non-persistent `SecretStore` for tests and SwiftUI previews.
final class InMemorySecretStore: SecretStore {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    init(seed: [SecretKey: String] = [:]) {
        for (key, value) in seed {
            storage[key.rawValue] = value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
