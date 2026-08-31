import XCTest
@testable import Sentwise

/// A recording interest client that suspends until the test completes it, so the
/// AppState race around account switches can be exercised deterministically.
final class SuspendingGoogleOAuthInterestClient: GoogleOAuthInterestRegistering, @unchecked Sendable {
    let didStart = XCTestExpectation(description: "interest registration started")

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var _callCount = 0
    private var _lastTopic: String?

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var lastTopic: String? { lock.lock(); defer { lock.unlock() }; return _lastTopic }

    func registerInterest(topic: String) async throws {
        await withCheckedContinuation { continuation in
            lock.lock()
            _callCount += 1
            _lastTopic = topic
            self.continuation = continuation
            lock.unlock()
            didStart.fulfill()
        }
    }

    func succeed() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// An `LLMProviding` double whose managed-account status fetch returns a fixed
/// status, so AppState can exercise `/v1/me` account-ID backfill in isolation.
final class ManagedStatusLLMProvider: LLMProviding, @unchecked Sendable {
    let status: ManagedAccountStatus?

    init(status: ManagedAccountStatus?) {
        self.status = status
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        LLMResponse(text: "")
    }

    func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
        status
    }
}
