import Security
@testable import Sentwise

/// A `SecretStore` whose `removeAll()` always throws, to drive the erase-all
/// Keychain-failure path.
final class ThrowingRemoveAllSecretStore: SecretStore {
    private var storage: [String: String] = [
        SecretKey.mailAppPassword(email: "me@gmail.com").rawValue: "app-pw"
    ]

    func set(_ value: String, for key: SecretKey) throws { storage[key.rawValue] = value }
    func value(for key: SecretKey) throws -> String? { storage[key.rawValue] }
    func remove(_ key: SecretKey) throws { storage[key.rawValue] = nil }
    func removeAll() throws { throw KeychainError.unexpectedStatus(errSecInternalError) }
}
