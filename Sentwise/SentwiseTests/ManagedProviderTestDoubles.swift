// Shared test doubles for ManagedProviderTests + ManagedProviderAppStateTests.
import SentwiseMail
import XCTest
@testable import Sentwise

/// A `ManagedSessionProviding` double for LLMService routing tests.
struct FixedSessionProvider: ManagedSessionProviding {
    let token: String
    let accountKey: String?

    init(token: String, accountKey: String? = nil) {
        self.token = token
        self.accountKey = accountKey
    }

    func currentSessionToken() async throws -> String { token }

    func currentManagedSession() async throws -> ManagedSessionToken {
        ManagedSessionToken(jwt: token, accountKey: accountKey)
    }
}

enum ManagedProviderSecretError: Error {
    case removeDenied
}

final class ManagedProviderFailingRemoveSecretStore: SecretStore {
    var failOnRemoveKeys: Set<SecretKey> = []
    private var storage: [String: String]

    init(seed: [SecretKey: String]) {
        storage = seed.reduce(into: [:]) { result, item in
            result[item.key.rawValue] = item.value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        if failOnRemoveKeys.contains(key) {
            throw ManagedProviderSecretError.removeDenied
        }
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        storage.removeAll()
    }
}

final class ManagedProviderQueueClerkTransport: ClerkHTTPTransport, @unchecked Sendable {
    private var responses: [ClerkHTTPResponse]

    init(_ responses: [ClerkHTTPResponse]) {
        self.responses = responses
    }

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        guard !responses.isEmpty else { return ClerkHTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        return responses.removeFirst()
    }
}

final class ManagedProviderSuspendedLLMTransport: LLMHTTPTransport, @unchecked Sendable {
    let didStartRequest = XCTestExpectation(description: "managed LLM request started")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, Error>?

    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            didStartRequest.fulfill()
        }
    }

    func complete(with result: Result<HTTPResponse, Error>) {
        lock.lock()
        let storedContinuation = continuation
        self.continuation = nil
        lock.unlock()
        storedContinuation?.resume(with: result)
    }
}

func managedProviderClerkResponse(
    _ json: String,
    status: Int = 200,
    clientToken: String? = nil
) -> ClerkHTTPResponse {
    var headers: [String: String] = [:]
    if let clientToken { headers["authorization"] = "Bearer \(clientToken)" }
    return ClerkHTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))
}
