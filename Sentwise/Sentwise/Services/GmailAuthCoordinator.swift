import Foundation
import os

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "GmailAuth")

/// Errors specific to the Gmail auth coordinator.
enum GmailAuthError: Error, Equatable {
    case missingCredentials
    case notConnected
}

/// Orchestrates connecting, refreshing, and disconnecting a Gmail account via
/// the PKCE desktop/loopback flow. All I/O (browser, loopback, network, clock)
/// is injected, so the orchestration is fully unit-testable.
@MainActor
final class GmailAuthCoordinator {

    private let store: GmailAuthStore
    private let tokenService: OAuthTokenService
    private let makeListener: () -> RedirectListener
    private let browser: BrowserOpening
    private let redirectTimeout: TimeInterval
    private let now: () -> Date
    private let makeState: () -> String

    init(
        store: GmailAuthStore,
        tokenService: OAuthTokenService,
        makeListener: @escaping () -> RedirectListener,
        browser: BrowserOpening,
        redirectTimeout: TimeInterval = 300,
        now: @escaping () -> Date = Date.init,
        makeState: @escaping () -> String = { PKCEGenerator.randomURLSafeString(byteCount: 16) }
    ) {
        self.store = store
        self.tokenService = tokenService
        self.makeListener = makeListener
        self.browser = browser
        self.redirectTimeout = redirectTimeout
        self.now = now
        self.makeState = makeState
    }

    var isConnected: Bool { store.isConnected }

    /// Runs the full connect flow: authorize in the browser, capture the
    /// redirect, exchange the code, and store the token.
    @discardableResult
    func connect() async throws -> OAuthToken {
        guard let credentials = try store.loadCredentials() else {
            throw GmailAuthError.missingCredentials
        }

        let pkce = PKCEGenerator.generate()
        let state = makeState()
        let listener = makeListener()
        defer { listener.stop() }

        let redirectURI = try await listener.start()
        let authURL = OAuthAuthorizationURL.make(
            clientID: credentials.clientID,
            redirectURI: redirectURI,
            scopes: GoogleOAuth.scopes,
            pkce: pkce,
            state: state
        )
        browser.open(authURL)

        let params = try await listener.waitForRedirect(timeout: redirectTimeout)
        guard params["state"] == state else {
            throw OAuthError.stateMismatch
        }
        if let error = params["error"] {
            throw OAuthError.authorizationDenied(error)
        }
        guard let code = params["code"] else {
            throw OAuthError.invalidResponse
        }

        let token = try await tokenService.exchange(
            code: code,
            verifier: pkce.verifier,
            credentials: credentials,
            redirectURI: redirectURI,
            now: now()
        )
        try saveFullyScopedToken(token)
        logger.info("Gmail account connected")
        return token
    }

    /// Returns a valid access token, refreshing it first if the stored one has
    /// expired.
    func validAccessToken() async throws -> String {
        guard let token = try store.loadToken() else {
            throw GmailAuthError.notConnected
        }
        guard token.isExpired(now: now()) else {
            return token.accessToken
        }
        guard let refreshToken = token.refreshToken else {
            throw OAuthError.missingRefreshToken
        }
        guard let credentials = try store.loadCredentials() else {
            throw GmailAuthError.missingCredentials
        }

        let refreshed = try await tokenService.refresh(
            refreshToken: refreshToken,
            credentials: credentials,
            now: now()
        )
        try saveFullyScopedToken(refreshed)
        return refreshed.accessToken
    }

    /// Disconnects the account by clearing the stored token (BYO credentials are
    /// kept so the user can reconnect without re-entering them).
    func disconnect() throws {
        try store.deleteToken()
        logger.info("Gmail account disconnected")
    }

    private func saveFullyScopedToken(_ token: OAuthToken) throws {
        let missingScopes = token.missingScopes(from: GoogleOAuth.scopes)
        guard missingScopes.isEmpty else {
            throw OAuthError.missingRequiredScopes(missingScopes)
        }
        try store.saveToken(token)
    }
}
