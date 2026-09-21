// LLM-side test doubles shared by the AppState suites (split from AppStateTestDoubles).
import SentwiseMail
import Security
import XCTest
@testable import Sentwise

final class FakeLLMProvider: LLMProviding, @unchecked Sendable {
    private let result: Result<Void, LLMError>
    private let completion: Result<LLMResponse, LLMError>
    private(set) var lastProvider: LLMProviderKind?
    private(set) var lastAPIKey: String?
    private(set) var lastModel: String?
    private(set) var lastBaseURL: String?
    private(set) var lastRequest: LLMRequest?

    init(
        result: Result<Void, LLMError>,
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: ""))
    ) {
        self.result = result
        self.completion = completion
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {
        lastProvider = provider
        lastAPIKey = apiKey
        lastModel = model
        lastBaseURL = baseURL
        try result.get()
    }

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        lastProvider = provider
        lastAPIKey = apiKey
        lastBaseURL = baseURL
        lastRequest = request
        return try completion.get()
    }
}

actor SequencedTestLLMProvider: LLMProviding {
    private var completions: [Result<LLMResponse, LLMError>]
    private var completedRequests = 0

    init(completions: [Result<LLMResponse, LLMError>]) {
        self.completions = completions
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        completedRequests += 1
        let next = completions.isEmpty
            ? Result.success(LLMResponse(text: "On it."))
            : completions.removeFirst()
        return try next.get()
    }

    func completionCount() -> Int { completedRequests }
}

final class SuspendedLLMProvider: LLMProviding, @unchecked Sendable {
    let didStartCompletion = XCTestExpectation(description: "LLM completion started")
    private let lock = NSLock()
    private var completionContinuation: CheckedContinuation<LLMResponse, Error>?
    private(set) var lastProvider: LLMProviderKind?
    private(set) var lastAPIKey: String?
    private(set) var lastRequest: LLMRequest?

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        lock.lock()
        lastProvider = provider
        lastAPIKey = apiKey
        lastRequest = request
        lock.unlock()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            completionContinuation = continuation
            lock.unlock()
            didStartCompletion.fulfill()
        }
    }

    func completeDraft(with result: Result<LLMResponse, Error>) {
        lock.lock()
        let continuation = completionContinuation
        completionContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

final class SuspendedLLMConnectionTester: LLMProviding, @unchecked Sendable {
    let didStartConnectionTest = XCTestExpectation(description: "LLM connection test started")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var lastProvider: LLMProviderKind?
    private(set) var lastAPIKey: String?
    private(set) var lastModel: String?

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {
        record(provider: provider, apiKey: apiKey, model: model)
        try await withCheckedThrowingContinuation { continuation in
            store(continuation)
            didStartConnectionTest.fulfill()
        }
    }

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        LLMResponse(text: "")
    }

    func complete(with result: Result<Void, Error>) {
        takeContinuation()?.resume(with: result)
    }

    private func record(provider: LLMProviderKind, apiKey: String, model: String) {
        lock.lock()
        lastProvider = provider
        lastAPIKey = apiKey
        lastModel = model
        lock.unlock()
    }

    private func store(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func takeContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        let pendingContinuation = continuation
        self.continuation = nil
        lock.unlock()
        return pendingContinuation
    }
}
