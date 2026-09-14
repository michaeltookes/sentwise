import Foundation
import os
import Security

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "Keychain")

/// Errors thrown by `KeychainStore`.
enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case dataEncodingFailed
}

/// A `SecretStore` backed by the macOS Keychain (generic-password items).
///
/// Items are scoped by a `service` identifier and marked accessible after first
/// unlock, this-device-only (never synced to iCloud). This uses the default
/// keychain and the generic-password class, so it needs no special entitlement.
final class KeychainStore: SecretStore {

    typealias AddItem = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias CopyMatching = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias DeleteItem = (CFDictionary) -> OSStatus
    typealias UpdateItem = (CFDictionary, CFDictionary) -> OSStatus

    static let shared = KeychainStore()

    private let service: String
    private let addItem: AddItem
    private let copyMatching: CopyMatching
    private let deleteItem: DeleteItem
    private let updateItem: UpdateItem

    init(
        service: String = "com.tookes.Sentwise",
        addItem: @escaping AddItem = SecItemAdd,
        copyMatching: @escaping CopyMatching = SecItemCopyMatching,
        deleteItem: @escaping DeleteItem = SecItemDelete,
        updateItem: @escaping UpdateItem = SecItemUpdate
    ) {
        self.service = service
        self.addItem = addItem
        self.copyMatching = copyMatching
        self.deleteItem = deleteItem
        self.updateItem = updateItem
    }

    func set(_ value: String, for key: SecretKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = updateItem(baseQuery(for: key) as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            logger.error("Keychain update failed for \(key.logSafeIdentifier, privacy: .public): \(updateStatus)")
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = addItem(attributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let retryStatus = updateItem(baseQuery(for: key) as CFDictionary, updateAttributes as CFDictionary)
            guard retryStatus == errSecSuccess else {
                logger.error("Keychain retry update failed for \(key.logSafeIdentifier, privacy: .public): \(retryStatus)")
                throw KeychainError.unexpectedStatus(retryStatus)
            }
        default:
            logger.error("Keychain set failed for \(key.logSafeIdentifier, privacy: .public): \(addStatus)")
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func value(for key: SecretKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            logger.error("Keychain read failed for \(key.logSafeIdentifier, privacy: .public): \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func remove(_ key: SecretKey) throws {
        let status = deleteItem(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func removeAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        // On macOS, SecItemDelete removes a single matching item per call, so
        // loop until nothing is left.
        var status = deleteItem(query as CFDictionary)
        while status == errSecSuccess {
            status = deleteItem(query as CFDictionary)
        }
        guard status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
