import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "GmailAuth")

/// Errors specific to the Gmail "Sign in with Google" flow (item 104).
enum GmailAuthError: Error, Equatable {
    /// This build ships without a Google OAuth client (feature switched off).
    case notConfigured
    /// No token is stored for the mailbox.
    case notConnected
    /// The stored grant is no longer valid (revoked, expired, password
    /// change); the user must sign in with Google again.
    case reauthorizationRequired
    /// Google did not tell us which address was authorized.
    case missingAccountEmail
    /// Google authorized a different address than the one the user asked for.
    case accountMismatch(expected: String, actual: String)
    /// A sign-in is already waiting in the browser.
    case alreadyInProgress
}

/// The result of a completed browser authorization.
struct GmailAuthorization: Equatable {
    let email: String
    let token: OAuthToken
}

/// The "Sign in with Google" phases, published for the UI (item 104).
///
/// `idle → awaitingBrowser → exchangingCode → idle` on success; any failure
/// lands in `failed(message)` and the next attempt starts again from there.
enum GmailAuthPhase: Equatable {
    case idle
    case awaitingBrowser
    case exchangingCode
    case failed(String)

    var isInProgress: Bool {
        self == .awaitingBrowser || self == .exchangingCode
    }
}

/// Orchestrates connecting, refreshing, and disconnecting Gmail mailboxes via
/// the PKCE desktop/loopback flow against the one bundled Sentwise client
/// (item 104; revives the parked item-3 engine). All I/O (browser, loopback,
/// network, clock, secrets) is injected, so the state machine is fully
/// unit-testable.
@MainActor
final class GmailAuthCoordinator {

    private let client: GoogleOAuthClientConfiguration
    private let store: GmailAuthStore
    private let tokenService: OAuthTokenService
    private let makeListener: () -> RedirectListener
    private let browser: BrowserOpening
    private let redirectTimeout: TimeInterval
    private let now: () -> Date
    private let makeState: () -> String

    private(set) var phase: GmailAuthPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    /// Observer hook so an `ObservableObject` façade can republish `phase`.
    var onPhaseChange: ((GmailAuthPhase) -> Void)?

    /// One refresh per mailbox at a time: concurrent pollers share it, so a
    /// burst of IMAP sessions never fires parallel refresh requests.
    private var refreshTasks: [String: (id: UUID, task: Task<String, Error>)] = [:]

    /// Bumped per mailbox on disconnect, and for every mailbox on
    /// `invalidateAll()`. A refresh captures the generation it started under
    /// and never saves or returns a token once it has moved on, so a response
    /// that lands after a disconnect, removal, or erase can't resurrect the
    /// mailbox's token.
    private var accountGenerations: [String: UInt64] = [:]
    private var globalGeneration: UInt64 = 0

    private struct TokenGeneration: Equatable {
        let global: UInt64
        let account: UInt64
    }

    private func generation(for key: String) -> TokenGeneration {
        TokenGeneration(global: globalGeneration, account: accountGenerations[key] ?? 0)
    }

    init(
        client: GoogleOAuthClientConfiguration,
        store: GmailAuthStore,
        tokenService: OAuthTokenService,
        makeListener: @escaping () -> RedirectListener = { LoopbackRedirectListener() },
        browser: BrowserOpening = NSWorkspaceBrowserOpener(),
        redirectTimeout: TimeInterval = 300,
        now: @escaping () -> Date = Date.init,
        makeState: @escaping () -> String = { PKCEGenerator.randomURLSafeString(byteCount: 16) }
    ) {
        self.client = client
        self.store = store
        self.tokenService = tokenService
        self.makeListener = makeListener
        self.browser = browser
        self.redirectTimeout = redirectTimeout
        self.now = now
        self.makeState = makeState
    }

    var clientID: String { client.clientID }

    // MARK: - Authorize

    /// Runs the browser flow: open Google's consent screen, capture the
    /// loopback redirect, exchange the code, and store the token under the
    /// authorized address (read from the ID token).
    ///
    /// - Parameter loginHint: an address to pre-select on Google's account
    ///   chooser. When `requireHintMatch` is set the authorized address must be
    ///   that one (used when re-authorizing a specific saved mailbox).
    func authorize(loginHint: String? = nil, requireHintMatch: Bool = false) async throws -> GmailAuthorization {
        guard !phase.isInProgress else { throw GmailAuthError.alreadyInProgress }
        phase = .awaitingBrowser
        do {
            let authorization = try await runAuthorization(loginHint: loginHint, requireHintMatch: requireHintMatch)
            phase = .idle
            logger.info("Gmail account authorized with Google")
            return authorization
        } catch {
            phase = (error is CancellationError) ? .idle : .failed(Self.message(for: error))
            throw error
        }
    }

    private func runAuthorization(loginHint: String?, requireHintMatch: Bool) async throws -> GmailAuthorization {
        let pkce = PKCEGenerator.generate()
        let state = makeState()
        let listener = makeListener()
        defer { listener.stop() }

        let redirectURI = try await listener.start()
        let hint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authURL = OAuthAuthorizationURL.make(
            clientID: client.clientID,
            redirectURI: redirectURI,
            scopes: GoogleOAuth.scopes,
            pkce: pkce,
            state: state,
            loginHint: (hint?.isEmpty ?? true) ? nil : hint
        )
        browser.open(authURL)

        let params = try await listener.waitForRedirect(timeout: redirectTimeout)
        try Task.checkCancellation()
        guard params["state"] == state else { throw OAuthError.stateMismatch }
        if let error = params["error"] { throw OAuthError.authorizationDenied(error) }
        guard let code = params["code"] else { throw OAuthError.invalidResponse }

        phase = .exchangingCode
        let token = try await tokenService.exchange(
            code: code,
            verifier: pkce.verifier,
            client: client,
            redirectURI: redirectURI,
            now: now()
        )
        try Task.checkCancellation()
        let email = try Self.authorizedEmail(token: token, loginHint: hint, requireHintMatch: requireHintMatch)
        try requireFullScope(token)
        guard token.refreshToken != nil else { throw OAuthError.missingRefreshToken }
        // Only the access/refresh material is kept; the ID token was read once.
        var stored = token
        stored.idToken = nil
        try store.saveToken(stored, for: email)
        return GmailAuthorization(email: email, token: stored)
    }

    static func authorizedEmail(token: OAuthToken, loginHint: String?, requireHintMatch: Bool) throws -> String {
        guard let email = token.idToken.flatMap(GoogleIDToken.email(fromIDToken:)) else {
            throw GmailAuthError.missingAccountEmail
        }
        if requireHintMatch, let loginHint, !loginHint.isEmpty,
           loginHint.caseInsensitiveCompare(email) != .orderedSame {
            throw GmailAuthError.accountMismatch(expected: loginHint, actual: email)
        }
        return email
    }

    // MARK: - Tokens

    /// Whether `email` has a stored Google token.
    func isConnected(_ email: String) -> Bool { store.hasToken(for: email) }

    /// Returns a valid access token for `email`, refreshing it first when the
    /// stored one has expired. Concurrent callers share one refresh.
    func validAccessToken(for email: String) async throws -> String {
        let key = SavedMailAccount.normalizedEmail(email)
        let startGeneration = generation(for: key)
        if let inFlight = refreshTasks[key] {
            let accessToken = try await inFlight.task.value
            try requireCurrent(startGeneration, for: key)
            return accessToken
        }
        guard let token = try store.loadToken(for: email) else {
            throw GmailAuthError.notConnected
        }
        guard token.isExpired(now: now()) else {
            return token.accessToken
        }
        guard let refreshToken = token.refreshToken else {
            throw GmailAuthError.reauthorizationRequired
        }

        let task = Task { () throws -> String in
            do {
                let refreshed = try await tokenService.refresh(refreshToken: refreshToken, client: client, now: now())
                // Disconnected (or erased) while the request was out: drop it.
                try requireCurrent(startGeneration, for: key)
                try requireFullScope(refreshed)
                try store.saveToken(refreshed, for: email)
                return refreshed.accessToken
            } catch OAuthError.server(let code, _) where code == "invalid_grant" {
                // Revoked, expired (7-day Testing-mode grants), or the user
                // changed their password: only a fresh sign-in fixes it.
                logger.info("Google grant no longer valid; re-authorization required")
                throw GmailAuthError.reauthorizationRequired
            }
        }
        let taskID = UUID()
        refreshTasks[key] = (taskID, task)
        defer {
            if refreshTasks[key]?.id == taskID { refreshTasks[key] = nil }
        }
        let accessToken = try await task.value
        try requireCurrent(startGeneration, for: key)
        return accessToken
    }

    private func requireCurrent(_ startGeneration: TokenGeneration, for key: String) throws {
        guard generation(for: key) == startGeneration else { throw GmailAuthError.notConnected }
    }

    /// Invalidates every outstanding token refresh, for all mailboxes, so none
    /// can save a token afterward (used before "Erase all local data").
    func invalidateAll() {
        globalGeneration &+= 1
        for entry in refreshTasks.values { entry.task.cancel() }
        refreshTasks.removeAll()
    }

    private func invalidate(_ key: String) {
        accountGenerations[key, default: 0] &+= 1
        refreshTasks.removeValue(forKey: key)?.task.cancel()
    }

    /// Forgets `email`'s token locally and, best effort, revokes the grant at
    /// Google so the app no longer appears in the user's third-party access
    /// list. A revocation network failure never blocks the local removal.
    func disconnect(_ email: String) async {
        invalidate(SavedMailAccount.normalizedEmail(email))
        let token = (try? store.loadToken(for: email)) ?? nil
        do {
            try store.deleteToken(for: email)
        } catch {
            logger.error("Couldn't remove a Google token from the Keychain: \(error.localizedDescription)")
        }
        guard let revocable = token?.refreshToken ?? token?.accessToken else { return }
        do {
            try await tokenService.revoke(token: revocable)
        } catch {
            logger.info("Google token revocation failed (ignored): \(error.localizedDescription)")
        }
    }

    private func requireFullScope(_ token: OAuthToken) throws {
        let missing = token.missingScopes(from: GoogleOAuth.requiredScopes)
        guard missing.isEmpty else { throw OAuthError.missingRequiredScopes(missing) }
    }

    // MARK: - Messages

    /// User-facing copy for a failed sign-in.
    static func message(for error: Error) -> String {
        if let error = error as? GmailAuthError { return message(for: error) }
        if let error = error as? OAuthError { return message(for: error) }
        return "Google sign-in failed. \(error.localizedDescription)"
    }

    private static func message(for error: GmailAuthError) -> String {
        switch error {
        case .notConfigured:
            return "Sign in with Google isn't available in this build. Use an app password instead."
        case .reauthorizationRequired, .notConnected:
            return "Your Google sign-in has expired or was revoked. Sign in with Google again."
        case .missingAccountEmail:
            return "Google didn't share which address you signed in with. Please try again."
        case .accountMismatch(let expected, let actual):
            return "You signed in as \(actual), but this account is \(expected). Choose \(expected) on Google's screen."
        case .alreadyInProgress:
            return "A Google sign-in is already open in your browser."
        }
    }

    private static func message(for error: OAuthError) -> String {
        switch error {
        case .authorizationDenied(let reason):
            return reason == "access_denied" ? "Google sign-in was canceled." : "Google sign-in failed (\(reason))."
        case .redirectTimedOut:
            return "Google sign-in timed out. Try again and finish in your browser."
        case .missingRequiredScopes:
            return "Sentwise needs permission to read and send your mail. Sign in again and allow Gmail access."
        case .missingRefreshToken:
            return "Google didn't grant offline access. Sign in again and approve all requested access."
        case .stateMismatch:
            return "The Google sign-in response didn't match this request. Please try again."
        case .server(let code, let description):
            return "Google sign-in failed: \(description ?? code)."
        case .invalidResponse:
            return "Google sign-in returned an unexpected response. Please try again."
        case .temporarilyUnavailable:
            return "Google's sign-in service is temporarily unavailable. Please try again in a few minutes."
        }
    }
}
