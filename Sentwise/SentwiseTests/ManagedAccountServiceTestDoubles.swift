// Shared test doubles for the ManagedAccountService suites
// (ManagedAccountServiceTests + ManagedAccountServiceSessionTests).
import XCTest
@testable import Sentwise

/// A fake `ClerkHTTPTransport` for driving `ManagedAccountService` end to end.
final class QueueClerkTransport: ClerkHTTPTransport, @unchecked Sendable {
    private var results: [Result<ClerkHTTPResponse, Error>]
    private(set) var callCount = 0
    private(set) var requests: [(url: URL, headers: [String: String], form: [String: String], method: String)] = []

    init(_ responses: [ClerkHTTPResponse]) {
        self.results = responses.map(Result.success)
    }

    init(results: [Result<ClerkHTTPResponse, Error>]) {
        self.results = results
    }

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        callCount += 1
        requests.append((url, headers, form, "POST"))
        guard !results.isEmpty else { return ClerkHTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        return try results.removeFirst().get()
    }

    func get(_ url: URL, headers: [String: String]) async throws -> ClerkHTTPResponse {
        callCount += 1
        requests.append((url, headers, [:], "GET"))
        guard !results.isEmpty else { return ClerkHTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        return try results.removeFirst().get()
    }
}

final class SuspendedClerkTransport: ClerkHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ClerkHTTPResponse, Never>?
    var onRequest: (() -> Void)?

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let onRequest = self.onRequest
            lock.unlock()
            onRequest?()
        }
    }

    func resume(with response: ClerkHTTPResponse) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
    }
}

final class MultiSuspendedClerkTransport: ClerkHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<ClerkHTTPResponse, Never>] = []
    private var recordedRequests: [(url: URL, headers: [String: String], form: [String: String])] = []
    var onRequest: ((Int) -> Void)?

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        await withCheckedContinuation { continuation in
            let requestNumber: Int
            let onRequest: ((Int) -> Void)?
            lock.lock()
            recordedRequests.append((url, headers, form))
            continuations.append(continuation)
            requestNumber = recordedRequests.count
            onRequest = self.onRequest
            lock.unlock()
            onRequest?(requestNumber)
        }
    }

    func resumeNext(with response: ClerkHTTPResponse) {
        lock.lock()
        let continuation = continuations.isEmpty ? nil : continuations.removeFirst()
        lock.unlock()
        continuation?.resume(returning: response)
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }

    func authorizationHeader(at index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard recordedRequests.indices.contains(index) else { return nil }
        return recordedRequests[index].headers["authorization"]
    }
}

func clerkReply(_ json: String, status: Int = 200, clientToken: String? = nil) -> ClerkHTTPResponse {
    var headers: [String: String] = [:]
    if let clientToken { headers["authorization"] = "Bearer \(clientToken)" }
    return ClerkHTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))
}

enum ManagedAccountTestSecretError: Error {
    case setDenied
    case removeDenied
}

final class ManagedAccountFailingSecretStore: SecretStore {
    var failOnSetKeys: Set<SecretKey> = []
    var failOnRemoveKeys: Set<SecretKey> = []
    private var storage: [String: String]

    init(seed: [SecretKey: String]) {
        storage = seed.reduce(into: [:]) { result, item in
            result[item.key.rawValue] = item.value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        if failOnSetKeys.contains(key) {
            throw ManagedAccountTestSecretError.setDenied
        }
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        if failOnRemoveKeys.contains(key) {
            throw ManagedAccountTestSecretError.removeDenied
        }
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        storage.removeAll()
    }
}
