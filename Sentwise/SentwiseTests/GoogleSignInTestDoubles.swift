import Foundation
import XCTest
@testable import Sentwise

// MARK: - Gated fakes

/// A redirect listener that waits until the test hands it the redirect.
final class GatedRedirectListener: RedirectListener, @unchecked Sendable {
    let didStartWaiting = XCTestExpectation(description: "waiting for the browser redirect")
    private let redirectURI: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?

    init(redirectURI: String) {
        self.redirectURI = redirectURI
    }

    func start() async throws -> String { redirectURI }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            didStartWaiting.fulfill()
        }
    }

    func release(_ params: [String: String]) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: params)
    }

    func stop() {}
}

/// A transport whose refresh requests (or, with `gatedURL`, requests to that
/// URL) wait until the test answers them; every other request answers
/// `otherResponse` immediately.
final class GatedRefreshTransport: HTTPTransport, @unchecked Sendable {
    let didStartRefresh = XCTestExpectation(description: "gated request started")
    private let gatedURL: URL?
    private let otherResponse: HTTPResponse
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private(set) var refreshCount = 0
    private(set) var lastGatedFields: [String: String] = [:]

    init(gatedURL: URL? = nil, otherResponse: HTTPResponse = HTTPResponse(statusCode: 200, body: Data())) {
        self.gatedURL = gatedURL
        self.otherResponse = otherResponse
    }

    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        let isGated = gatedURL.map { $0 == url } ?? (fields["grant_type"] == "refresh_token")
        guard isGated else { return otherResponse }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            refreshCount += 1
            lastGatedFields = fields
            self.continuation = continuation
            lock.unlock()
            didStartRefresh.fulfill()
        }
    }

    func completeRefresh(_ response: HTTPResponse) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
    }
}
