import XCTest
@testable import Sentwise

@MainActor
final class GmailAuthorizationCleanupTests: XCTestCase {
    private struct Harness {
        let coordinator: GmailAuthCoordinator
        let store: GmailAuthStore
        let secrets: AuthorizationSecretStore
        let transport: AuthorizationTransport
    }

    private func makeHarness(
        email: String? = "selected@gmail.com",
        scope: String? = GoogleOAuth.mailScope,
        refreshToken: String? = "new-refresh"
    ) throws -> Harness {
        var fields: [String: Any] = ["access_token": "new-access", "expires_in": 3600]
        if let scope { fields["scope"] = scope }
        if let email { fields["id_token"] = GmailAuthCoordinatorTests.idToken(email: email) }
        if let refreshToken { fields["refresh_token"] = refreshToken }
        let transport = AuthorizationTransport(response: HTTPResponse(
            statusCode: 200, body: try JSONSerialization.data(withJSONObject: fields)
        ))
        let secrets = AuthorizationSecretStore()
        let store = GmailAuthStore(secrets: secrets)
        let coordinator = GmailAuthCoordinator(
            client: GoogleOAuthClientConfiguration(clientID: "client.apps.googleusercontent.com"),
            store: store,
            tokenService: OAuthTokenService(transport: transport),
            makeListener: { FakeRedirectListener(redirectURI: "http://127.0.0.1:9999", params: ["code": "code", "state": "state"]) },
            browser: SpyBrowser(),
            makeState: { "state" }
        )
        return Harness(coordinator: coordinator, store: store, secrets: secrets, transport: transport)
    }

    private var existingToken: OAuthToken {
        OAuthToken(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantFuture,
                   scope: GoogleOAuth.mailScope, tokenType: "Bearer")
    }

    func testMismatchRevokesOnlyTheUnconnectedSelectedAccount() async throws {
        let harness = try makeHarness()
        try harness.store.saveToken(existingToken, for: "expected@gmail.com")

        do {
            _ = try await harness.coordinator.authorize(loginHint: "expected@gmail.com", requireHintMatch: true)
            XCTFail("expected account mismatch")
        } catch {
            XCTAssertEqual(error as? GmailAuthError, .accountMismatch(expected: "expected@gmail.com", actual: "selected@gmail.com"))
        }

        XCTAssertEqual(harness.transport.revokedTokens, ["new-refresh"])
        XCTAssertEqual(try harness.store.loadToken(for: "expected@gmail.com"), existingToken)
        XCTAssertFalse(harness.store.hasToken(for: "selected@gmail.com"))
    }

    func testMismatchPreservesAnAlreadyConnectedSelectedAccount() async throws {
        let harness = try makeHarness(email: "SELECTED@gmail.com")
        try harness.store.saveToken(existingToken, for: "selected@gmail.com")

        do {
            _ = try await harness.coordinator.authorize(loginHint: "expected@gmail.com", requireHintMatch: true)
            XCTFail("expected account mismatch")
        } catch {
            XCTAssertEqual(error as? GmailAuthError, .accountMismatch(expected: "expected@gmail.com", actual: "SELECTED@gmail.com"))
        }

        XCTAssertTrue(harness.transport.revokedTokens.isEmpty)
        XCTAssertEqual(try harness.store.loadToken(for: "selected@gmail.com"), existingToken)
    }

    func testMissingScopeRevokesNewGrant() async throws {
        for scope in ["openid email", ""] {
            let harness = try makeHarness(scope: scope)
            do {
                _ = try await harness.coordinator.authorize()
                XCTFail("expected missing scope")
            } catch {
                XCTAssertEqual(error as? OAuthError, .missingRequiredScopes([GoogleOAuth.mailScope]))
            }
            XCTAssertEqual(harness.transport.revokedTokens, ["new-refresh"])
            XCTAssertFalse(harness.store.hasToken(for: "selected@gmail.com"))
        }
    }

    func testMissingRefreshTokenRevokesAccessToken() async throws {
        let harness = try makeHarness(refreshToken: nil)
        do {
            _ = try await harness.coordinator.authorize()
            XCTFail("expected missing refresh token")
        } catch {
            XCTAssertEqual(error as? OAuthError, .missingRefreshToken)
        }
        XCTAssertEqual(harness.transport.revokedTokens, ["new-access"])
    }

    func testUnusableReplacementPreservesExistingGrant() async throws {
        let harness = try makeHarness(scope: "openid email")
        try harness.store.saveToken(existingToken, for: "selected@gmail.com")
        do {
            _ = try await harness.coordinator.authorize()
            XCTFail("expected missing scope")
        } catch {
            XCTAssertEqual(error as? OAuthError, .missingRequiredScopes([GoogleOAuth.mailScope]))
        }
        XCTAssertTrue(harness.transport.revokedTokens.isEmpty)
        XCTAssertEqual(try harness.store.loadToken(for: "selected@gmail.com"), existingToken)
    }

    func testKeychainSaveFailureRevokesNewGrant() async throws {
        let harness = try makeHarness()
        harness.secrets.failWrites = true
        do {
            _ = try await harness.coordinator.authorize()
            XCTFail("expected save failure")
        } catch {
            XCTAssertTrue(error is AuthorizationSecretStore.Failure)
        }
        XCTAssertEqual(harness.transport.revokedTokens, ["new-refresh"])
        XCTAssertFalse(harness.store.hasToken(for: "selected@gmail.com"))
    }

    func testKeychainSaveFailurePreservesExistingGrant() async throws {
        let harness = try makeHarness()
        try harness.store.saveToken(existingToken, for: "selected@gmail.com")
        harness.secrets.failWrites = true
        do {
            _ = try await harness.coordinator.authorize()
            XCTFail("expected save failure")
        } catch {
            XCTAssertTrue(error is AuthorizationSecretStore.Failure)
        }
        XCTAssertTrue(harness.transport.revokedTokens.isEmpty)
        XCTAssertEqual(try harness.store.loadToken(for: "selected@gmail.com"), existingToken)
    }

    func testCancellationAfterExchangeRevokesFromAnUncancelledTask() async throws {
        let harness = try makeHarness()
        harness.transport.onExchange = { withUnsafeCurrentTask { $0?.cancel() } }
        let attempt = Task { try await harness.coordinator.authorize() }
        do {
            _ = try await attempt.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(harness.transport.revokedTokens, ["new-refresh"])
        XCTAssertFalse(harness.transport.revocationWasCancelled)
        XCTAssertFalse(harness.store.hasToken(for: "selected@gmail.com"))
        XCTAssertEqual(harness.coordinator.phase, .idle)
    }

    func testSuspendedTokenOperationsCleanUpExchangedGrant() async throws {
        let harness = try makeHarness()
        harness.coordinator.invalidateAll()
        do {
            _ = try await harness.coordinator.authorize()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(harness.transport.revokedTokens, ["new-refresh"])
        XCTAssertFalse(harness.store.hasToken(for: "selected@gmail.com"))
    }

    func testFailedRevocationDoesNotReplaceTheOriginalError() async throws {
        let harness = try makeHarness(scope: "openid")
        harness.transport.failRevocation = true
        do {
            _ = try await harness.coordinator.authorize()
            XCTFail("expected missing scope")
        } catch {
            XCTAssertEqual(error as? OAuthError, .missingRequiredScopes([GoogleOAuth.mailScope]))
        }
        XCTAssertEqual(harness.transport.revokedTokens, ["new-refresh"])
    }

    func testUnknownAccountDoesNotRiskRevokingAnExistingGrant() async throws {
        let harness = try makeHarness(email: nil)
        try harness.store.saveToken(existingToken, for: "expected@gmail.com")
        do {
            _ = try await harness.coordinator.authorize(loginHint: "expected@gmail.com", requireHintMatch: true)
            XCTFail("expected missing email")
        } catch {
            XCTAssertEqual(error as? GmailAuthError, .missingAccountEmail)
        }
        XCTAssertTrue(harness.transport.revokedTokens.isEmpty)
        XCTAssertEqual(try harness.store.loadToken(for: "expected@gmail.com"), existingToken)
    }

    func testUnreadableKeychainDoesNotRiskRevokingAnExistingGrant() async throws {
        let harness = try makeHarness(scope: "openid")
        try harness.store.saveToken(existingToken, for: "selected@gmail.com")
        harness.secrets.failReads = true
        do {
            _ = try await harness.coordinator.authorize()
            XCTFail("expected missing scope")
        } catch {
            XCTAssertEqual(error as? OAuthError, .missingRequiredScopes([GoogleOAuth.mailScope]))
        }
        XCTAssertTrue(harness.transport.revokedTokens.isEmpty)
        harness.secrets.failReads = false
        XCTAssertEqual(try harness.store.loadToken(for: "selected@gmail.com"), existingToken)
    }

    func testSuccessfulAuthorizationKeepsNewGrant() async throws {
        let harness = try makeHarness()
        let result = try await harness.coordinator.authorize()
        XCTAssertEqual(try harness.store.loadToken(for: result.email), result.token)
        XCTAssertTrue(harness.transport.revokedTokens.isEmpty)
    }

    func testOmittedScopeAdoptsRequestedScopesWithoutRevokingGrant() async throws {
        let harness = try makeHarness(scope: nil)
        let result = try await harness.coordinator.authorize()

        XCTAssertEqual(result.token.scope, GoogleOAuth.scopes.joined(separator: " "))
        XCTAssertEqual(try harness.store.loadToken(for: result.email), result.token)
        XCTAssertTrue(harness.transport.revokedTokens.isEmpty)
        XCTAssertEqual(harness.coordinator.phase, .idle)
    }
}

private final class AuthorizationSecretStore: SecretStore {
    struct Failure: Error {}
    private let base = InMemorySecretStore()
    var failWrites = false
    var failReads = false

    func set(_ value: String, for key: SecretKey) throws {
        if failWrites { throw Failure() }
        try base.set(value, for: key)
    }
    func value(for key: SecretKey) throws -> String? {
        if failReads { throw Failure() }
        return try base.value(for: key)
    }
    func remove(_ key: SecretKey) throws { try base.remove(key) }
    func removeAll() throws { try base.removeAll() }
}

private final class AuthorizationTransport: HTTPTransport {
    let response: HTTPResponse
    var onExchange: (() -> Void)?
    var failRevocation = false
    private(set) var revokedTokens: [String] = []
    private(set) var revocationWasCancelled = false

    init(response: HTTPResponse) { self.response = response }

    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        if url == GoogleOAuth.revocationEndpoint {
            revokedTokens.append(fields["token"] ?? "")
            revocationWasCancelled = Task.isCancelled
            if failRevocation { throw URLError(.notConnectedToInternet) }
            return HTTPResponse(statusCode: 200, body: Data())
        }
        onExchange?()
        return response
    }
}
