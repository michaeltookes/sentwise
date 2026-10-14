import XCTest
@testable import Sentwise

/// Overlapping sign-ins for one mailbox (item 6i (a)). Sign-in A finished the
/// browser flow and is verifying IMAP when sign-in B starts; if A then fails,
/// its cleanup must not revoke at Google while B is mid-consent (Google
/// revokes the whole grant, which would also kill B's new authorization).
@MainActor
final class GmailAuthorizationOverlapTests: XCTestCase {
    private let state = "state"

    private struct Harness {
        let coordinator: GmailAuthCoordinator
        let store: GmailAuthStore
        let transport: OverlapTransport
        let gate: GatedRedirectListener
    }

    /// A completes immediately; B (the second `authorize`) waits on `gate`.
    private func makeHarness(exchanges: [(email: String, refresh: String)]) -> Harness {
        let store = GmailAuthStore(secrets: InMemorySecretStore())
        let transport = OverlapTransport(exchanges: exchanges.map { Self.exchangeBody(email: $0.email, refresh: $0.refresh) })
        let gate = GatedRedirectListener(redirectURI: "http://127.0.0.1:9999")
        var listeners: [RedirectListener] = [
            FakeRedirectListener(redirectURI: "http://127.0.0.1:9999", params: ["code": "a", "state": state]),
            gate
        ]
        let coordinator = GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: "client.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { listeners.removeFirst() },
            browser: SpyBrowser(),
            makeState: { self.state }
        )
        return Harness(coordinator: coordinator, store: store, transport: transport, gate: gate)
    }

    private static func exchangeBody(email: String, refresh: String) -> Data {
        let fields: [String: Any] = [
            "access_token": "at-\(refresh)", "refresh_token": refresh, "expires_in": 3600,
            "scope": GoogleOAuth.mailScope, "id_token": GmailAuthCoordinatorTests.idToken(email: email)
        ]
        return (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
    }

    /// Starts B and waits until it is in the browser (past the revocation barrier).
    private func startSecondSignIn(
        _ harness: Harness, loginHint: String? = nil, requireHintMatch: Bool = false
    ) async -> Task<GmailAuthorization, Error> {
        let task = Task { try await harness.coordinator.authorize(loginHint: loginHint, requireHintMatch: requireHintMatch) }
        await fulfillment(of: [harness.gate.didStartWaiting], timeout: 2)
        return task
    }

    private func waitForRevocation(_ harness: Harness) async {
        let revoked = expectation(description: "revocation sent")
        revoked.assertForOverFulfill = false
        harness.transport.onRevoke = { revoked.fulfill() }
        if !harness.transport.revokedTokens.isEmpty { revoked.fulfill() }
        await fulfillment(of: [revoked], timeout: 2)
    }

    func testOlderAttemptFailingBeforeNewerAdoptsNeverRevokesTheNewGrant() async throws {
        let harness = makeHarness(exchanges: [("me@gmail.com", "rt-a"), ("me@gmail.com", "rt-b")])
        let first = try await harness.coordinator.authorize(loginHint: "me@gmail.com", requireHintMatch: true)
        let second = await startSecondSignIn(harness, loginHint: "me@gmail.com", requireHintMatch: true)

        // A's IMAP verification fails while B is in the browser.
        await harness.coordinator.discard(first)
        XCTAssertTrue(harness.transport.revokedTokens.isEmpty, "B passed the barrier; revoking now would kill its grant")
        XCTAssertFalse(harness.store.hasToken(for: "me@gmail.com"), "A's token is still removed locally")

        harness.gate.release(["code": "b", "state": state])
        let adopted = try await second.value

        XCTAssertEqual(try harness.store.loadToken(for: "me@gmail.com"), adopted.token)
        await Task.yield()
        XCTAssertTrue(harness.transport.revokedTokens.isEmpty, "B adopted a token: A's deferred revoke is dropped")
    }

    func testDeferredRevocationRunsWhenTheNewerAttemptFailsWithoutAToken() async throws {
        let harness = makeHarness(exchanges: [("me@gmail.com", "rt-a")])
        let first = try await harness.coordinator.authorize()
        let second = await startSecondSignIn(harness)

        await harness.coordinator.discard(first)
        XCTAssertTrue(harness.transport.revokedTokens.isEmpty)

        harness.gate.release(["error": "access_denied", "state": state])
        do {
            _ = try await second.value
            XCTFail("expected the second sign-in to be denied")
        } catch {
            XCTAssertEqual(error as? OAuthError, .authorizationDenied("access_denied"))
        }

        await waitForRevocation(harness)
        XCTAssertEqual(harness.transport.revokedTokens, ["rt-a"], "nothing adopted: A's orphaned grant is revoked")
    }

    func testDeferredRevocationRunsWhenTheNewerAttemptAdoptsAnotherMailbox() async throws {
        let harness = makeHarness(exchanges: [("me@gmail.com", "rt-a"), ("other@gmail.com", "rt-b")])
        let first = try await harness.coordinator.authorize()
        let second = await startSecondSignIn(harness)

        await harness.coordinator.discard(first)
        XCTAssertTrue(harness.transport.revokedTokens.isEmpty, "an unbound sign-in could still pick this mailbox")

        harness.gate.release(["code": "b", "state": state])
        let adopted = try await second.value
        XCTAssertEqual(adopted.email, "other@gmail.com")

        await waitForRevocation(harness)
        XCTAssertEqual(harness.transport.revokedTokens, ["rt-a"])
        XCTAssertTrue(harness.store.hasToken(for: "other@gmail.com"))
    }

    func testOlderAttemptFailingAfterNewerAdoptsLeavesTheNewGrantAlone() async throws {
        let harness = makeHarness(exchanges: [("me@gmail.com", "rt-a"), ("me@gmail.com", "rt-b")])
        let first = try await harness.coordinator.authorize(loginHint: "me@gmail.com", requireHintMatch: true)
        let second = await startSecondSignIn(harness, loginHint: "me@gmail.com", requireHintMatch: true)
        harness.gate.release(["code": "b", "state": state])
        let adopted = try await second.value

        await harness.coordinator.discard(first)

        XCTAssertTrue(harness.transport.revokedTokens.isEmpty)
        XCTAssertEqual(try harness.store.loadToken(for: "me@gmail.com"), adopted.token)
    }

    func testNewerSignInBoundToAnotherMailboxDoesNotHoldBackCleanup() async throws {
        let harness = makeHarness(exchanges: [("me@gmail.com", "rt-a")])
        let first = try await harness.coordinator.authorize()
        let second = await startSecondSignIn(harness, loginHint: "other@gmail.com", requireHintMatch: true)

        await harness.coordinator.discard(first)

        XCTAssertEqual(harness.transport.revokedTokens, ["rt-a"])
        XCTAssertFalse(harness.store.hasToken(for: "me@gmail.com"))
        second.cancel()
        harness.gate.release(["error": "access_denied", "state": state])
        _ = try? await second.value
    }
}

/// Answers each code exchange from a queue and records revocations.
private final class OverlapTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [Data]
    private var revoked: [String] = []
    var onRevoke: (() -> Void)?

    init(exchanges: [Data]) { self.exchanges = exchanges }

    var revokedTokens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        lock.lock()
        if url == GoogleOAuth.revocationEndpoint {
            revoked.append(fields["token"] ?? "")
            let onRevoke = onRevoke
            lock.unlock()
            onRevoke?()
            return HTTPResponse(statusCode: 200, body: Data())
        }
        let body = exchanges.isEmpty ? Data() : exchanges.removeFirst()
        lock.unlock()
        return HTTPResponse(statusCode: 200, body: body)
    }
}
