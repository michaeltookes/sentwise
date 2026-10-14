import Foundation
import os

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "GmailAuth")

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
    /// A token refresh was made obsolete (re-authorization, disconnect, erase)
    /// while in flight. Transient: retry against the current grant.
    case superseded
    /// The previous grant's revocation is still in flight after the bounded
    /// wait. Retryable: sign in again in a moment.
    case revocationPending
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
    private let revocationWaitTimeout: TimeInterval
    private let revocations = GoogleRevocationTracker()
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
    /// Set by `invalidateAll()` (erase-all) until `resumeTokenOperations()`:
    /// while suspended no token is loaded, refreshed, saved, or retried, so
    /// nothing can be restored between the invalidation and the Keychain wipe.
    private(set) var tokenOperationsSuspended = false

    /// A mailbox's grant generation. Mail operations capture the one their
    /// access token was issued under (`validAccessTokenWithGrant(for:)`) so a
    /// late rejection can be checked with `isGrantSuperseded(_:for:)`.
    struct TokenGeneration: Equatable, Sendable {
        fileprivate let global: UInt64
        fileprivate let account: UInt64
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
        revocationWaitTimeout: TimeInterval = 10,
        now: @escaping () -> Date = Date.init,
        makeState: @escaping () -> String = { PKCEGenerator.randomURLSafeString(byteCount: 16) }
    ) {
        self.client = client
        self.store = store
        self.tokenService = tokenService
        self.makeListener = makeListener
        self.browser = browser
        self.redirectTimeout = redirectTimeout
        self.revocationWaitTimeout = revocationWaitTimeout
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
        // Google revokes the whole grant for a revoked refresh token, so a revoke
        // that lands after the new consent would invalidate the new grant too.
        // If it is still out after the bounded wait, fail retryably rather than
        // open consent while a late revoke could still kill the new grant.
        guard await revocations.waitForPending(timeout: revocationWaitTimeout) else {
            logger.info("A pending Google revocation didn't finish in time; sign-in deferred")
            throw GmailAuthError.revocationPending
        }
        try Task.checkCancellation()
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
            requestedScopes: GoogleOAuth.scopes,
            now: now()
        )
        do {
            return try adoptAuthorization(token, loginHint: hint, requireHintMatch: requireHintMatch)
        } catch {
            await revokeUnadoptedToken(token)
            throw error
        }
    }

    private func adoptAuthorization(_ token: OAuthToken, loginHint: String?, requireHintMatch: Bool) throws -> GmailAuthorization {
        try Task.checkCancellation()
        let email = try Self.authorizedEmail(token: token, loginHint: loginHint, requireHintMatch: requireHintMatch)
        try requireFullScope(token)
        guard token.refreshToken != nil else { throw OAuthError.missingRefreshToken }
        // Only the access/refresh material is kept; the ID token was read once.
        var stored = token
        stored.idToken = nil
        // A refresh still out for this mailbox belongs to the old grant: retire
        // it so its late result (success or invalid_grant) can't overwrite or
        // reject the new one, and so verification doesn't join it.
        invalidate(SavedMailAccount.normalizedEmail(email))
        guard !tokenOperationsSuspended else { throw CancellationError() }
        try store.saveToken(stored, for: email)
        return GmailAuthorization(email: email, token: stored)
    }

    /// A rejected exchange must not leave a new mailbox authorized remotely.
    /// Revocation affects the whole account grant, including older tokens, so
    /// only revoke when we can establish that the actual account has no token.
    private func revokeUnadoptedToken(_ token: OAuthToken) async {
        guard let email = token.idToken.flatMap(GoogleIDToken.email(fromIDToken:)) else {
            logger.info("Couldn't identify a rejected Google grant; revocation skipped to preserve existing accounts")
            return
        }
        do {
            guard try store.loadToken(for: email) == nil else { return }
        } catch {
            logger.info("Couldn't check stored Google grants; revocation skipped to preserve existing accounts")
            return
        }
        // The tracker runs revocation in its own task, even if this sign-in was
        // canceled, and makes a subsequent sign-in wait for cleanup to finish.
        await revokeRemovedToken(token)
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
    ///
    /// A refresh that a re-authorization or disconnect of this mailbox made
    /// obsolete ends `superseded` (never an auth failure); the call then
    /// retries once against the current state: the new grant's token, or
    /// `notConnected`. A global invalidation (erase-all) never retries: it
    /// ends `notConnected`, and token operations stay suspended until resumed.
    func validAccessToken(for email: String) async throws -> String {
        try await validAccessTokenWithGrant(for: email).accessToken
    }

    /// `validAccessToken(for:)` plus the grant generation the token belongs
    /// to, read in the same main-actor turn the token is returned in.
    func validAccessTokenWithGrant(for email: String) async throws -> (accessToken: String, grant: TokenGeneration) {
        do {
            return try await currentAccessToken(for: email)
        } catch GmailAuthError.superseded {
            return try await currentAccessToken(for: email)
        }
    }

    /// Whether `email`'s grant was replaced (re-authorization) or disconnected
    /// since `grant` was captured. An erase (global invalidation or suspended
    /// token operations) is not a supersession: it stays final.
    func isGrantSuperseded(_ grant: TokenGeneration, for email: String) -> Bool {
        let current = generation(for: SavedMailAccount.normalizedEmail(email))
        return current != grant && !tokenOperationsSuspended && current.global == grant.global
    }

    private func currentAccessToken(for email: String) async throws -> (accessToken: String, grant: TokenGeneration) {
        guard !tokenOperationsSuspended else { throw GmailAuthError.notConnected }
        let key = SavedMailAccount.normalizedEmail(email)
        let startGeneration = generation(for: key)
        if let inFlight = refreshTasks[key] {
            let accessToken = try await inFlight.task.value
            try requireCurrent(startGeneration, for: key)
            return (accessToken, startGeneration)
        }
        guard let token = try store.loadToken(for: email) else {
            throw GmailAuthError.notConnected
        }
        guard token.isExpired(now: now()) else {
            return (token.accessToken, startGeneration)
        }
        guard let refreshToken = token.refreshToken else {
            throw GmailAuthError.reauthorizationRequired
        }

        let task = Task { () throws -> String in
            let refreshed: OAuthToken
            do {
                refreshed = try await tokenService.refresh(
                    refreshToken: refreshToken, grantedScope: token.scope, client: client, now: now()
                )
            } catch {
                // The old grant's failure (invalid_grant, cancellation) says
                // nothing about the grant that replaced it.
                try requireCurrent(startGeneration, for: key)
                if case OAuthError.server(let code, _) = error, code == "invalid_grant" {
                    // Revoked, expired (7-day Testing-mode grants), or the user
                    // changed their password: only a fresh sign-in fixes it.
                    logger.info("Google grant no longer valid; re-authorization required")
                    throw GmailAuthError.reauthorizationRequired
                }
                throw error
            }
            // Re-authorized, disconnected, or erased while the request was out: drop it.
            try requireCurrent(startGeneration, for: key)
            try requireFullScope(refreshed)
            try store.saveToken(refreshed, for: email)
            return refreshed.accessToken
        }
        let taskID = UUID()
        refreshTasks[key] = (taskID, task)
        defer {
            if refreshTasks[key]?.id == taskID { refreshTasks[key] = nil }
        }
        let accessToken = try await task.value
        try requireCurrent(startGeneration, for: key)
        return (accessToken, startGeneration)
    }

    private func requireCurrent(_ startGeneration: TokenGeneration, for key: String) throws {
        let current = generation(for: key)
        guard current != startGeneration else { return }
        // Erase-all (global) is final for this operation; only a per-account
        // re-authorization or disconnect is worth a retry.
        if tokenOperationsSuspended || current.global != startGeneration.global {
            throw GmailAuthError.notConnected
        }
        throw GmailAuthError.superseded
    }

    /// Invalidates every outstanding token refresh, for all mailboxes, and
    /// suspends token operations (used before "Erase all local data", which
    /// calls `resumeTokenOperations()` once the Keychain is wiped).
    func invalidateAll() {
        globalGeneration &+= 1
        tokenOperationsSuspended = true
        for entry in refreshTasks.values { entry.task.cancel() }
        refreshTasks.removeAll()
    }

    /// Ends the suspension started by `invalidateAll()`.
    func resumeTokenOperations() {
        tokenOperationsSuspended = false
    }

    private func invalidate(_ key: String) {
        accountGenerations[key, default: 0] &+= 1
        refreshTasks.removeValue(forKey: key)?.task.cancel()
    }

    /// Forgets `email`'s token locally and, best effort, revokes the grant at
    /// Google so the app no longer appears in the user's third-party access
    /// list. A revocation network failure never blocks the local removal.
    func disconnect(_ email: String) async {
        let token = (try? store.loadToken(for: email)) ?? nil
        do {
            _ = try removeLocalToken(for: email)
        } catch {
            logger.error("Couldn't remove a Google token from the Keychain: \(error.localizedDescription)")
        }
        if let token { await revokeRemovedToken(token) }
    }

    /// Cleanup for one specific authorization: deletes and revokes `token`
    /// only while it is still the stored grant for `email`. When a newer
    /// sign-in has replaced it, nothing is deleted or revoked (revoking the old
    /// grant would also kill the new one at Google).
    func disconnect(_ email: String, ifStoredTokenIs token: OAuthToken) async {
        guard let stored = (try? store.loadToken(for: email)) ?? nil,
              Self.isSameGrant(stored, token) else { return }
        do {
            _ = try removeLocalToken(for: email)
        } catch {
            logger.error("Couldn't remove a Google token from the Keychain: \(error.localizedDescription)")
            return
        }
        await revokeRemovedToken(token)
    }

    static func isSameGrant(_ lhs: OAuthToken, _ rhs: OAuthToken) -> Bool {
        if let left = lhs.refreshToken, let right = rhs.refreshToken { return left == right }
        return lhs.accessToken == rhs.accessToken
    }

    /// Deletes `email`'s stored token (invalidating any refresh in flight) and
    /// returns it, so a caller whose larger operation fails can put it back
    /// with `restoreLocalToken(_:for:)`. Throws when the Keychain delete fails.
    func removeLocalToken(for email: String) throws -> OAuthToken? {
        invalidate(SavedMailAccount.normalizedEmail(email))
        guard let token = try store.loadToken(for: email) else { return nil }
        try store.deleteToken(for: email)
        return token
    }

    /// Puts back a token taken by `removeLocalToken(for:)` (rollback).
    func restoreLocalToken(_ token: OAuthToken, for email: String) throws {
        try store.saveToken(token, for: email)
    }

    /// Revokes a removed token's grant at Google, best effort and tracked so
    /// a new sign-in waits for it (see `GoogleRevocationTracker`).
    func revokeRemovedToken(_ token: OAuthToken) async {
        let revocable = token.refreshToken ?? token.accessToken
        guard !revocable.isEmpty else { return }
        let tokenService = tokenService
        await revocations.run {
            do {
                try await tokenService.revoke(token: revocable)
            } catch {
                logger.info("Google token revocation failed (ignored): \(error.localizedDescription)")
            }
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
        case .revocationPending:
            return "Sentwise is still disconnecting your previous Google sign-in. Try again in a moment."
        case .superseded:
            return "Your Google sign-in changed while Sentwise was refreshing it. Please try again."
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
