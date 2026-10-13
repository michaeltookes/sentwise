// Appended to keychain-snapshot.swift by test-keychain-snapshot.sh so the same
// script implementation can be exercised without accessing a user's Keychain.
import XCTest

final class KeychainSnapshotTests: XCTestCase {
    let service = "com.tookes.Sentwise"
    let mailbox = "mail.appPassword.person@example.com"

    func item(_ account: String, modified: TimeInterval = 1_800_000_000) -> [String: Any] {
        [
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrModificationDate as String: Date(timeIntervalSince1970: modified),
            kSecValueData as String: Data("secret-canary".utf8)
        ]
    }

    func snapshot(_ items: [[String: Any]], status: OSStatus = errSecSuccess) throws -> String {
        try capture(service: service, keychainPath: nil) { query, result in
            let query = query as? [String: Any] ?? [:]
            XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
            XCTAssertEqual(query[kSecAttrService as String] as? String, self.service)
            XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
            XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
            XCTAssertNil(query[kSecAttrAccount as String])
            XCTAssertNil(query[kSecReturnData as String])
            result?.pointee = items as CFArray
            return status
        }
    }

    func testDynamicAccountsAndStableOrdering() throws {
        let items = [item(mailbox), item("managed.clientToken"), item("future.provider.apiKey")]
        let state = try snapshot(items)
        XCTAssertEqual(state, try snapshot(items.reversed()))
        XCTAssertEqual(state.split(separator: "\n").count, 3)
        XCTAssertTrue(state.contains(mailbox))
        XCTAssertTrue(state.contains("future.provider.apiKey"))
        XCTAssertFalse(state.contains("secret-canary"))
        XCTAssertFalse(state.contains("v_Data"))
    }

    func testDetectsAdditionRemovalAndRewrite() throws {
        let initial = try snapshot([item("managed.clientToken"), item(mailbox)])
        XCTAssertNotEqual(initial, try snapshot([item("managed.clientToken")]))
        XCTAssertNotEqual(initial, try snapshot([item("managed.clientToken"), item(mailbox), item("new.account")]))
        XCTAssertNotEqual(initial, try snapshot([item("managed.clientToken"), item(mailbox, modified: 1_800_000_001)]))
        XCTAssertNotEqual(try snapshot([item(mailbox)]), try snapshot([], status: errSecItemNotFound))
    }

    func testEscapingAndDuplicateAccounts() throws {
        let account = "mail.appPassword.quoted\"\tline\n@example.com"
        let state = try snapshot([item(account), item(account)])
        let lines = state.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(row["account"] as? String, account)
            XCTAssertEqual(Set(row.keys), Set(["service", "account", "mdat"]))
        }
    }

    func testOnlyItemNotFoundMeansEmpty() throws {
        XCTAssertEqual(try snapshot([], status: errSecItemNotFound), "")
        for status in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed, errSecParam] {
            XCTAssertThrowsError(try snapshot([], status: status))
        }
        XCTAssertThrowsError(try snapshot([]))
    }

    func testIncompleteMetadataFailsClosed() {
        for key in [kSecAttrAccount, kSecAttrModificationDate, kSecAttrService] {
            var attributes = item(mailbox)
            attributes.removeValue(forKey: key as String)
            XCTAssertThrowsError(try snapshot([attributes]))
        }
        var attributes = item(mailbox)
        attributes[kSecAttrModificationDate as String] = "not a date"
        XCTAssertThrowsError(try snapshot([attributes]))
    }
}

let suite = KeychainSnapshotTests.defaultTestSuite
suite.run()
exit(suite.testRun?.hasSucceeded == true ? 0 : 1)
