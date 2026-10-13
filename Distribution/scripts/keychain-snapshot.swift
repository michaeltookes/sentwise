// Attribute-only companion to keychain-tripwire.sh. No account allowlist: a
// fresh service-wide query on each pass also detects newly created accounts.
import Foundation
import Security

enum SnapshotError: Error {
    case keychainStatus(OSStatus)
    case incompleteAttributes
}

func checkStatus(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw SnapshotError.keychainStatus(status) }
}

typealias CopyMatching = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

func capture(
    service: String,
    keychainPath: String?,
    copyMatching: CopyMatching = SecItemCopyMatching
) throws -> String {
    // These legacy APIs target the same file-based login keychain as the app.
    // Disable interaction in this process so a locked keychain cannot hang CI.
    try checkStatus(SecKeychainSetUserInteractionAllowed(false))
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: true
    ]
    if let keychainPath {
        var keychain: SecKeychain?
        try checkStatus(SecKeychainOpen(keychainPath, &keychain))
        guard let keychain else { throw SnapshotError.incompleteAttributes }
        // Open can return a reference even when the file does not exist.
        var keychainStatus: SecKeychainStatus = 0
        try checkStatus(SecKeychainGetStatus(keychain, &keychainStatus))
        query[kSecMatchSearchList as String] = [keychain]
    }

    var result: CFTypeRef?
    let status = copyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    try checkStatus(status)
    guard let items = result as? [[String: Any]], !items.isEmpty else {
        throw SnapshotError.incompleteAttributes
    }

    let rows = try items.map { attributes -> String in
        guard let itemService = attributes[kSecAttrService as String] as? String,
              itemService == service,
              let account = attributes[kSecAttrAccount as String] as? String,
              let modified = attributes[kSecAttrModificationDate as String] as? Date else {
            throw SnapshotError.incompleteAttributes
        }
        // Serialize only the required metadata, never the raw result dictionary.
        let row: [String: Any] = [
            "service": itemService, "account": account, "mdat": modified.timeIntervalSince1970
        ]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else {
            throw SnapshotError.incompleteAttributes
        }
        return line
    }
    // Preserve duplicate rows (e.g. identical accounts in separate keychains).
    // Sorting prevents Keychain enumeration order from producing false alarms.
    return rows.sorted().joined(separator: "\n")
}

#if !KEYCHAIN_SNAPSHOT_TESTING
guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("usage: keychain-snapshot.swift <service> [keychain]\n", stderr)
    exit(2)
}
do {
    let keychainPath = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : nil
    print(try capture(service: CommandLine.arguments[1], keychainPath: keychainPath))
} catch {
    fputs("error: Keychain metadata capture failed (\(error)); refusing an unreadable snapshot.\n", stderr)
    exit(3)
}
#endif
