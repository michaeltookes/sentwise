import XCTest
@testable import Sentwise

/// Integration tests against the real macOS Keychain.
///
/// They run locally to verify the real Security-framework round-trip, and skip
/// automatically where the Keychain isn't usable (e.g. a CI runner without an
/// unlocked login keychain) by probing it first. They use a dedicated test
/// service so they never touch real app secrets, and clean up after themselves.
final class KeychainStoreTests: XCTestCase {

    private let store = KeychainStore(service: KeychainStore.testService)
    private let key = SecretKey(rawValue: "test.sample")

    override func setUpWithError() throws {
        try skipIfKeychainUnavailable()
        try store.removeAll()
    }

    /// Skips the test when the Keychain can't be used in this environment.
    private func skipIfKeychainUnavailable() throws {
        let probe = SecretKey(rawValue: "test.probe")
        do {
            try store.set("ok", for: probe)
            let value = try store.value(for: probe)
            try store.remove(probe)
            if value != "ok" {
                throw XCTSkip("Keychain did not round-trip; skipping integration tests")
            }
        } catch let error as KeychainError {
            throw XCTSkip("Keychain unavailable in this environment (\(error)); skipping")
        }
    }

    override func tearDownWithError() throws {
        try? store.removeAll()
    }

    func testSetAndGetRoundTrips() throws {
        try store.set("secret-value", for: key)
        XCTAssertEqual(try store.value(for: key), "secret-value")
    }

    func testValueIsNilWhenAbsent() throws {
        XCTAssertNil(try store.value(for: SecretKey(rawValue: "test.missing")))
    }

    func testSetOverwritesExistingValue() throws {
        try store.set("first", for: key)
        try store.set("second", for: key)
        XCTAssertEqual(try store.value(for: key), "second")
    }

    func testRemoveDeletesValue() throws {
        try store.set("x", for: key)
        try store.remove(key)
        XCTAssertNil(try store.value(for: key))
    }

    func testRemoveAllClearsEverything() throws {
        try store.set("a", for: SecretKey(rawValue: "test.a"))
        try store.set("b", for: SecretKey(rawValue: "test.b"))
        try store.removeAll()
        XCTAssertNil(try store.value(for: SecretKey(rawValue: "test.a")))
        XCTAssertNil(try store.value(for: SecretKey(rawValue: "test.b")))
    }
}

/// Pure tests for the default-service selection (item 115): the production
/// service is the hard default; only an explicit truthy `SENTWISE_TEST_KEYCHAIN`
/// flips to the fixed, compiled-in test service, so no environment value can
/// ever redirect the store to the installed app's items — or to an arbitrary
/// service.
final class KeychainStoreServiceSelectionTests: XCTestCase {

    func testDefaultServiceIsProductionWhenVariableAbsent() {
        XCTAssertEqual(
            KeychainStore.resolvedDefaultService(environment: [:]),
            KeychainStore.productionService
        )
    }

    func testTruthyVariableSelectsTestService() {
        for value in ["1", "true", "yes", " TRUE ", "Yes"] {
            XCTAssertEqual(
                KeychainStore.resolvedDefaultService(
                    environment: [KeychainStore.testKeychainEnvironmentKey: value]
                ),
                KeychainStore.testService,
                "expected '\(value)' to select the test service"
            )
        }
    }

    func testEmptyOrGarbageVariableStaysOnProduction() {
        for value in ["", "   ", "0", "false", "no", "2", "garbage", "com.evil.Service"] {
            XCTAssertEqual(
                KeychainStore.resolvedDefaultService(
                    environment: [KeychainStore.testKeychainEnvironmentKey: value]
                ),
                KeychainStore.productionService,
                "expected '\(value)' to stay on the production service"
            )
        }
    }

    func testTestServiceIsDistinctFromProduction() {
        XCTAssertNotEqual(KeychainStore.testService, KeychainStore.productionService)
        XCTAssertEqual(KeychainStore.productionService, "com.tookes.Sentwise")
        XCTAssertEqual(KeychainStore.testService, "com.tookes.Sentwise.tests")
    }
}

final class KeychainStoreBehaviorTests: XCTestCase {
    private let key = SecretKey(rawValue: "test.sample")

    func testSetUpdatesExistingValueWithoutAdding() throws {
        let fakeKeychain = FakeKeychain(value: "first")
        let store = fakeKeychain.makeStore()

        try store.set("second", for: key)

        XCTAssertEqual(try store.value(for: key), "second")
        XCTAssertEqual(fakeKeychain.updateCallCount, 1)
        XCTAssertEqual(fakeKeychain.addCallCount, 0)
    }

    func testSetFallsBackToAddWhenValueIsMissing() throws {
        let fakeKeychain = FakeKeychain(
            updateStatuses: [errSecItemNotFound],
            addStatuses: [errSecSuccess]
        )
        let store = fakeKeychain.makeStore()

        try store.set("created", for: key)

        XCTAssertEqual(try store.value(for: key), "created")
        XCTAssertEqual(fakeKeychain.updateCallCount, 1)
        XCTAssertEqual(fakeKeychain.addCallCount, 1)
    }

    func testSetPreservesExistingValueWhenUpdateFails() throws {
        let fakeKeychain = FakeKeychain(
            value: "first",
            updateStatuses: [errSecInteractionNotAllowed]
        )
        let store = fakeKeychain.makeStore()

        XCTAssertThrowsError(try store.set("second", for: key)) { error in
            XCTAssertEqual(error as? KeychainError, .unexpectedStatus(errSecInteractionNotAllowed))
        }

        XCTAssertEqual(try store.value(for: key), "first")
        XCTAssertEqual(fakeKeychain.updateCallCount, 1)
        XCTAssertEqual(fakeKeychain.addCallCount, 0)
    }

    func testSetRetriesUpdateWhenAddRacesWithAnotherWriter() throws {
        let fakeKeychain = FakeKeychain(
            updateStatuses: [errSecItemNotFound, errSecSuccess],
            addStatuses: [errSecDuplicateItem]
        )
        let store = fakeKeychain.makeStore()

        try store.set("second", for: key)

        XCTAssertEqual(try store.value(for: key), "second")
        XCTAssertEqual(fakeKeychain.updateCallCount, 2)
        XCTAssertEqual(fakeKeychain.addCallCount, 1)
    }
}

private final class FakeKeychain {
    private var data: Data?
    private var updateStatuses: [OSStatus]
    private var addStatuses: [OSStatus]

    private(set) var addCallCount = 0
    private(set) var updateCallCount = 0

    init(
        value: String? = nil,
        updateStatuses: [OSStatus] = [],
        addStatuses: [OSStatus] = []
    ) {
        self.data = value?.data(using: .utf8)
        self.updateStatuses = updateStatuses
        self.addStatuses = addStatuses
    }

    func makeStore() -> KeychainStore {
        KeychainStore(
            service: "com.tookes.Sentwise.fake-tests",
            addItem: addItem,
            copyMatching: copyMatching,
            deleteItem: deleteItem,
            updateItem: updateItem
        )
    }

    private func addItem(
        _ attributes: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        addCallCount += 1
        let status = addStatuses.isEmpty ? (data == nil ? errSecSuccess : errSecDuplicateItem) : addStatuses.removeFirst()
        if status == errSecSuccess {
            data = valueData(from: attributes)
        }
        result?.pointee = nil
        return status
    }

    private func copyMatching(
        _ _: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        guard let data else {
            result?.pointee = nil
            return errSecItemNotFound
        }

        result?.pointee = data as NSData
        return errSecSuccess
    }

    private func deleteItem(_ _: CFDictionary) -> OSStatus {
        guard data != nil else {
            return errSecItemNotFound
        }

        data = nil
        return errSecSuccess
    }

    private func updateItem(
        _ _: CFDictionary,
        _ attributesToUpdate: CFDictionary
    ) -> OSStatus {
        updateCallCount += 1
        let status = updateStatuses.isEmpty ? (data == nil ? errSecItemNotFound : errSecSuccess) : updateStatuses.removeFirst()
        if status == errSecSuccess {
            data = valueData(from: attributesToUpdate)
        }
        return status
    }

    private func valueData(from attributes: CFDictionary) -> Data? {
        let dictionary = attributes as NSDictionary
        return dictionary[kSecValueData as String] as? Data
    }
}
