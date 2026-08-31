import XCTest
@testable import Sentwise

/// Tests for the "notify me when Sign in with Google is available" client and its
/// local don't-re-offer store (item 75). The client speaks the managed service's
/// `POST /v1/interest` contract; the store persists the confirmation so the button
/// isn't shown again after a click.
final class GoogleOAuthInterestTests: XCTestCase {

    private func json(_ string: String, status: Int) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(string.utf8))
    }

    // MARK: - Client

    func testRegisterInterestPostsTopicWithBearerTokenTo204() async throws {
        let transport = FakeLLMTransport(response: HTTPResponse(statusCode: 204, body: Data()))
        let client = GoogleOAuthInterestClient(
            sessionProvider: FixedSessionProvider(token: "tok-abc", accountKey: "acct-session"),
            transport: transport
        )

        let registration = try await client.registerInterest(topic: "google-oauth")

        XCTAssertEqual(registration.accountKey, "acct-session")
        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastURL, ManagedInference.interestEndpoint)
        XCTAssertEqual(transport.lastHeaders?["authorization"], "Bearer tok-abc")
        XCTAssertEqual(transport.lastHeaders?["content-type"], "application/json")
        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["topic"] as? String, "google-oauth")
    }

    func testRegisterInterestMapsUnauthorizedToManagedNotSignedIn() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"unauthorized","message":"Sign in first."}}"#, status: 401
        ))
        let client = GoogleOAuthInterestClient(
            sessionProvider: FixedSessionProvider(token: "tok", accountKey: "acct-session"),
            transport: transport
        )

        do {
            try await client.registerInterest(topic: "google-oauth")
            XCTFail("expected an error on 401")
        } catch let error as GoogleOAuthInterestRegistrationFailure {
            guard let underlying = error.underlying as? LLMError,
                  case .managedNotSignedIn = underlying else {
                return XCTFail("expected managedNotSignedIn, got \(error.underlying)")
            }
            XCTAssertEqual(error.accountKey, "acct-session")
        } catch {
            XCTFail("expected registration failure, got \(error)")
        }
    }

    func testRegisterInterestSurfacesServerErrorOnOtherStatuses() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"server_error","message":"boom"}}"#, status: 500
        ))
        let client = GoogleOAuthInterestClient(
            sessionProvider: FixedSessionProvider(token: "tok", accountKey: "acct-session"),
            transport: transport
        )

        do {
            try await client.registerInterest(topic: "google-oauth")
            XCTFail("expected an error on 500")
        } catch let error as GoogleOAuthInterestRegistrationFailure {
            guard let underlying = error.underlying as? LLMError,
                  case .http = underlying else {
                return XCTFail("expected http error, got \(error.underlying)")
            }
            XCTAssertEqual(error.accountKey, "acct-session")
        } catch {
            XCTFail("expected registration failure, got \(error)")
        }
    }

    // MARK: - Store

    func testStorePersistsPerAccountKey() {
        let defaults = ephemeralDefaults()
        let store = UserDefaultsGoogleOAuthInterestStore(defaults: defaults, key: "test-interest-keys")

        XCTAssertFalse(store.isRegistered(accountKey: "acct-a"))
        store.markRegistered(accountKey: "acct-a")
        XCTAssertTrue(store.isRegistered(accountKey: "acct-a"))
        XCTAssertFalse(store.isRegistered(accountKey: "acct-b"), "another account is independent")

        // Survives a fresh store reading the same defaults (persistence).
        let reopened = UserDefaultsGoogleOAuthInterestStore(defaults: defaults, key: "test-interest-keys")
        XCTAssertTrue(reopened.isRegistered(accountKey: "acct-a"))
    }

    func testStoreMarkIsIdempotent() {
        let defaults = ephemeralDefaults()
        let store = UserDefaultsGoogleOAuthInterestStore(defaults: defaults, key: "test-interest-keys")
        store.markRegistered(accountKey: "acct-a")
        store.markRegistered(accountKey: "acct-a")
        XCTAssertTrue(store.isRegistered(accountKey: "acct-a"))
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "GoogleOAuthInterestTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

/// An in-memory `GoogleOAuthInterestStoring` for AppState state-machine tests.
final class InMemoryGoogleOAuthInterestStore: GoogleOAuthInterestStoring, @unchecked Sendable {
    private var keys: Set<String> = []
    func isRegistered(accountKey: String) -> Bool { keys.contains(accountKey) }
    func markRegistered(accountKey: String) { keys.insert(accountKey) }
}

/// A recording `GoogleOAuthInterestRegistering` double: counts calls and can be
/// told to fail, so AppState's interest state machine is tested without network.
final class RecordingGoogleOAuthInterestClient: GoogleOAuthInterestRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastTopic: String?
    let error: Error?

    init(error: Error? = nil) { self.error = error }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var lastTopic: String? { lock.lock(); defer { lock.unlock() }; return _lastTopic }

    func registerInterest(topic: String) async throws -> GoogleOAuthInterestRegistration {
        lock.lock()
        _callCount += 1
        _lastTopic = topic
        lock.unlock()
        if let error { throw error }
        return GoogleOAuthInterestRegistration(accountKey: nil)
    }
}
