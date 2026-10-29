import SentwiseMail
import Security
import XCTest
@testable import Sentwise

final class AppStateFailingSecretStore: SecretStore {
    var failOnValue: Set<SecretKey> = []
    var failOnSet: SecretKey?
    var failOnRemove: SecretKey?
    private var storage: [String: String]

    init(seed: [SecretKey: String] = [:]) {
        storage = seed.reduce(into: [:]) { result, item in
            result[item.key.rawValue] = item.value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        if failOnSet == key {
            throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        }
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        if failOnValue.contains(key) {
            throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        }
        return storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        if failOnRemove == key {
            throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        }
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        storage.removeAll()
    }
}
