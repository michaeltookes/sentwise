import XCTest
@testable import Sentwise

/// Behavior tests for the `SecretStore` contract, exercised via the
/// deterministic in-memory implementation so they run anywhere (including CI).
final class SecretStoreTests: XCTestCase {

    func testSetAndGetRoundTrips() throws {
        let store = InMemorySecretStore()
        try store.set("token-123", for: .gmailToken)
        XCTAssertEqual(try store.value(for: .gmailToken), "token-123")
    }

    func testValueIsNilWhenAbsent() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.value(for: .googleClientID))
    }

    func testSetOverwritesExistingValue() throws {
        let store = InMemorySecretStore()
        try store.set("old", for: .googleClientSecret)
        try store.set("new", for: .googleClientSecret)
        XCTAssertEqual(try store.value(for: .googleClientSecret), "new")
    }

    func testRemoveDeletesValue() throws {
        let store = InMemorySecretStore()
        try store.set("x", for: .gmailToken)
        try store.remove(.gmailToken)
        XCTAssertNil(try store.value(for: .gmailToken))
    }

    func testRemoveAllClearsEverything() throws {
        let store = InMemorySecretStore()
        try store.set("a", for: .gmailToken)
        try store.set("b", for: .googleClientID)
        try store.removeAll()
        XCTAssertNil(try store.value(for: .gmailToken))
        XCTAssertNil(try store.value(for: .googleClientID))
    }

    func testSeededStoreExposesInitialValues() throws {
        let store = InMemorySecretStore(seed: [.gmailToken: "seeded"])
        XCTAssertEqual(try store.value(for: .gmailToken), "seeded")
    }

    func testHasValueReflectsPresenceAndEmptiness() throws {
        let store = InMemorySecretStore()
        XCTAssertFalse(store.hasValue(for: .gmailToken))
        try store.set("", for: .gmailToken)
        XCTAssertFalse(store.hasValue(for: .gmailToken), "empty string is not a value")
        try store.set("real", for: .gmailToken)
        XCTAssertTrue(store.hasValue(for: .gmailToken))
    }

    func testLLMAPIKeyIsProviderScoped() {
        XCTAssertEqual(SecretKey.llmAPIKey(provider: "anthropic").rawValue, "llm.anthropic.apiKey")
        XCTAssertNotEqual(
            SecretKey.llmAPIKey(provider: "anthropic"),
            SecretKey.llmAPIKey(provider: "openai")
        )
    }

    func testMailAppPasswordIsAccountScopedAndNormalized() {
        XCTAssertEqual(
            SecretKey.mailAppPassword(email: "me@gmail.com").rawValue,
            "mail.appPassword.me@gmail.com"
        )
        // Casing/whitespace normalize to one identity so a re-typed email maps to
        // the same Keychain item.
        XCTAssertEqual(
            SecretKey.mailAppPassword(email: "  Me@Gmail.com "),
            SecretKey.mailAppPassword(email: "me@gmail.com")
        )
        XCTAssertNotEqual(
            SecretKey.mailAppPassword(email: "me@gmail.com"),
            SecretKey.mailAppPassword(email: "me@att.net")
        )
        // Per-account keys are distinct from the legacy shared slot.
        XCTAssertNotEqual(SecretKey.mailAppPassword(email: "me@gmail.com"), .mailAppPassword)
    }

    func testPerAccountSecretsAreIsolated() throws {
        let store = InMemorySecretStore()
        try store.set("gmail-pw", for: .mailAppPassword(email: "me@gmail.com"))
        try store.set("att-pw", for: .mailAppPassword(email: "me@att.net"))

        // Removing one account's secret leaves the other untouched.
        try store.remove(.mailAppPassword(email: "me@gmail.com"))
        XCTAssertNil(try store.value(for: .mailAppPassword(email: "me@gmail.com")))
        XCTAssertEqual(try store.value(for: .mailAppPassword(email: "me@att.net")), "att-pw")
    }

    // MARK: - Log-safe identifier (A-L4)

    func testLogSafeIdentifierNeverLeaksAccountEmail() {
        let email = "marcus@example.com"
        let identifier = SecretKey.mailAppPassword(email: email).logSafeIdentifier
        // The kind prefix stays useful, but the account email is never present.
        XCTAssertTrue(identifier.hasPrefix("mail.appPassword#"), identifier)
        XCTAssertFalse(identifier.contains(email))
        XCTAssertFalse(identifier.contains("marcus"))
        XCTAssertFalse(identifier.contains("example.com"))
    }

    func testLogSafeIdentifierIsStableAndPerKeyDistinct() {
        // Stable across calls (SHA-256, not the per-process-randomized Hasher)…
        XCTAssertEqual(
            SecretKey.mailAppPassword(email: "me@gmail.com").logSafeIdentifier,
            SecretKey.mailAppPassword(email: "me@gmail.com").logSafeIdentifier
        )
        // …and distinct per account, so a specific failing item is still traceable.
        XCTAssertNotEqual(
            SecretKey.mailAppPassword(email: "me@gmail.com").logSafeIdentifier,
            SecretKey.mailAppPassword(email: "me@att.net").logSafeIdentifier
        )
    }

    func testLogSafeIdentifierKindPrefixForWellKnownKeys() {
        XCTAssertTrue(SecretKey.managedClientToken.logSafeIdentifier.hasPrefix("managed.clientToken#"))
        XCTAssertTrue(SecretKey.gmailToken.logSafeIdentifier.hasPrefix("gmail.token#"))
    }
}
