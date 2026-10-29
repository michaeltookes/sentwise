import Combine
import Foundation
import os
import SentwiseMail

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "GoogleSignIn")

/// How a Google-signed-in mailbox is represented in the per-account credential
/// slot (item 104).
///
/// Every connected mailbox owns one per-account slot
/// (`SecretKey.mailAppPassword(email:)`, item 48) that the account switching,
/// removal, rollback, and multi-account watcher paths already carry around.
/// A "Sign in with Google" mailbox stores this fixed, non-secret marker there
/// instead of an app password; the real OAuth tokens live in their own
/// per-account Keychain item (`SecretKey.gmailOAuthToken(email:)`). The mail
/// layer (`GoogleOAuthMailProvider`) recognizes the marker and swaps in a
/// fresh access token right before each IMAP/SMTP session, so none of the
/// existing account plumbing needs to know which auth method an account uses.
enum GoogleMailCredential {
    /// Not a secret and never sent to a server: it can never authenticate on
    /// its own because the provider replaces it with an XOAUTH2 token.
    static let marker = "sentwise-google-oauth:v1"

    static let imapHost = "imap.gmail.com"
    static let imapPort = 993

    static func isMarker(_ value: String) -> Bool { value == marker }

    static func isGoogleSignIn(_ credentials: MailAccountCredentials) -> Bool {
        isMarker(credentials.appPassword)
    }

    /// Credentials for a Google-signed-in mailbox.
    static func credentials(email: String) -> MailAccountCredentials {
        MailAccountCredentials(email: email, appPassword: marker, host: imapHost, port: imapPort)
    }

    /// Prefix of every auth-failure detail the OAuth path produces, so the
    /// generic "check your app password" copy is never shown for it.
    static let failurePrefix = "Google sign-in"
    static let reauthorizationDetail =
        "Google sign-in expired or was revoked — sign in with Google again in Settings → Email Account."

    static func isGoogleSignInFailureDetail(_ detail: String) -> Bool {
        detail.hasPrefix(failurePrefix)
    }
}

/// How the connect screen should steer the user (item 104): one-click Google
/// sign-in for Gmail and Google Workspace, app password for everyone else.
enum MailConnectMethod: Equatable {
    case googleSignIn
    case appPassword

    /// The primary connect method for what the user has typed so far.
    ///
    /// Google sign-in is primary only when this build ships a client AND the
    /// address/host could be Google: an empty address, a Gmail address, or a
    /// custom domain (it may be Google Workspace) on the Gmail IMAP host. A
    /// recognized non-Google provider (Yahoo, iCloud, …) or a non-Google IMAP
    /// host keeps the app-password path, which is also the fallback whenever
    /// the feature is switched off.
    static func recommended(email: String, host: String, isGoogleSignInAvailable: Bool) -> MailConnectMethod {
        guard isGoogleSignInAvailable else { return .appPassword }
        if let kind = EmailProviderKind.forEmail(email), kind != .gmail {
            return .appPassword
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHost.isEmpty, EmailProviderKind.forHost(trimmedHost) != .gmail {
            return .appPassword
        }
        return .googleSignIn
    }
}

/// The app's "Sign in with Google" service (item 104): an observable façade
/// over `GmailAuthCoordinator` that the views watch for progress, and the
/// access-token source behind `GoogleOAuthMailProvider`.
///
/// `coordinator` is nil when the build has no bundled client, which switches
/// the feature off everywhere. The token store stays reachable regardless, so
/// local cleanup (disconnect, removal, switching to an app password) always
/// deletes a mailbox's tokens even in a build without a client. Available on
/// every plan tier (item 104 — tier placement pending owner confirmation; no
/// gate is applied here).
@MainActor
final class GoogleMailAuthService: ObservableObject {
    @Published private(set) var phase: GmailAuthPhase = .idle
    /// Microsoft only: set when sign-in stopped for an administrator's approval (item 31, T31-5).
    @Published var adminApproval: MicrosoftAdminApprovalRequest?

    private(set) var coordinator: GmailAuthCoordinator?
    /// Independent of `coordinator` (and of client availability).
    private let tokenStore: GmailAuthStore?
    /// The marker (`OAuthProviderConfiguration.credentialMarker`) that stands in
    /// for the app password of a mailbox signed in through this service's provider.
    let credentialMarker: String
    private var signInTask: Task<GmailAuthorization, Error>?
    /// The normalized address the pending sign-in was started for, if any.
    private var pendingLoginHint: String?
    /// Saved-mailbox removals, so a sign-in that started before a mailbox was
    /// removed can't restore it when the browser finally comes back.
    private var accountRemovalSequence: UInt64 = 0
    private var lastAccountRemoval: [String: UInt64] = [:]

    init(
        coordinator: GmailAuthCoordinator?,
        tokenStore: GmailAuthStore? = nil,
        credentialMarker: String = GoogleMailCredential.marker
    ) {
        self.tokenStore = tokenStore
        self.credentialMarker = credentialMarker
        install(coordinator)
    }

    /// The production service: the bundled client from Info.plist (if any),
    /// tokens in `secrets`.
    static func live(secrets: SecretStore) -> GoogleMailAuthService {
        let configuration = GoogleOAuthClientConfiguration.bundled()
        let store = GmailAuthStore(
            secrets: secrets,
            keychainPrefix: configuration?.keychainPrefix ?? OAuthProviderConfiguration.googleKeychainPrefix
        )
        let coordinator = configuration.map { client in
            GmailAuthCoordinator(
                client: client,
                store: store,
                tokenService: OAuthTokenService(transport: URLSessionTransport())
            )
        }
        return GoogleMailAuthService(
            coordinator: coordinator,
            tokenStore: store,
            credentialMarker: configuration?.credentialMarker ?? GoogleMailCredential.marker
        )
    }

    /// Swaps the engine (tests inject one wired to fakes).
    func install(_ coordinator: GmailAuthCoordinator?) {
        self.coordinator?.onPhaseChange = nil
        self.coordinator = coordinator
        phase = coordinator?.phase ?? .idle
        coordinator?.onPhaseChange = { [weak self] phase in self?.phase = phase }
    }

    var isAvailable: Bool { coordinator != nil }

    /// Runs the browser sign-in. Cancellable through `cancelSignIn()`.
    func signIn(loginHint: String? = nil, requireHintMatch: Bool = false) async throws -> GmailAuthorization {
        guard let coordinator else { throw GmailAuthError.notConfigured }
        guard signInTask == nil else { throw GmailAuthError.alreadyInProgress }
        let task = Task { try await coordinator.authorize(loginHint: loginHint, requireHintMatch: requireHintMatch) }
        signInTask = task
        pendingLoginHint = loginHint.map(SavedMailAccount.normalizedEmail)
        defer {
            signInTask = nil
            pendingLoginHint = nil
        }
        let authorization = try await task.value
        signInTimes[SavedMailAccount.normalizedEmail(authorization.email)] = Date()
        return authorization
    }

    /// When each mailbox last finished a browser sign-in in this run (not
    /// persisted): lets a failure right after sign-in be told from an old grant.
    private var signInTimes: [String: Date] = [:]

    /// Seconds since `email` last signed in during this run; a day when unknown.
    func signInAge(for email: String) -> TimeInterval {
        signInTimes[SavedMailAccount.normalizedEmail(email)].map { Date().timeIntervalSince($0) } ?? 86_400
    }

    /// Whether a browser sign-in is pending.
    var isSignInPending: Bool { signInTask != nil }

    /// One generation shared by every mailbox connection attempt, app password
    /// and Google alike: starting an attempt supersedes (and, for a pending
    /// Google sign-in, cancels) the previous one, and each path checks its
    /// generation before it commits a result.
    private(set) var connectionAttempt: UInt64 = 0

    func beginConnectionAttempt() -> UInt64 {
        connectionAttempt &+= 1
        cancelSignIn()
        return connectionAttempt
    }

    func isCurrentConnectionAttempt(_ attempt: UInt64) -> Bool {
        connectionAttempt == attempt
    }

    /// A mark to compare against later with `wasAccountRemoved(_:since:)`.
    func accountRemovalMark() -> UInt64 { accountRemovalSequence }

    /// Records that the saved mailbox `email` was removed, and cancels a
    /// pending sign-in that was started for it.
    func noteAccountRemoved(_ email: String) {
        let key = SavedMailAccount.normalizedEmail(email)
        accountRemovalSequence &+= 1
        lastAccountRemoval[key] = accountRemovalSequence
        if pendingLoginHint == key { cancelSignIn() }
    }

    /// Whether `email` was removed after `mark` was taken.
    func wasAccountRemoved(_ email: String, since mark: UInt64) -> Bool {
        (lastAccountRemoval[SavedMailAccount.normalizedEmail(email)] ?? 0) > mark
    }

    /// Abandons a sign-in that is waiting on the browser.
    func cancelSignIn() {
        signInTask?.cancel()
    }

    func isConnected(_ email: String) -> Bool {
        coordinator?.isConnected(email) ?? false
    }

    func accessToken(for email: String) async throws -> String {
        try await accessTokenWithGrant(for: email).accessToken
    }

    /// The access token plus the grant generation it was issued under.
    func accessTokenWithGrant(
        for email: String
    ) async throws -> (accessToken: String, grant: GmailAuthCoordinator.TokenGeneration) {
        guard let coordinator else { throw GmailAuthError.notConfigured }
        return try await coordinator.validAccessTokenWithGrant(for: email)
    }

    /// Whether `email`'s grant was replaced or disconnected since `grant`.
    func isGrantSuperseded(_ grant: GmailAuthCoordinator.TokenGeneration, for email: String) -> Bool {
        coordinator?.isGrantSuperseded(grant, for: email) ?? false
    }

    /// Invalidates every in-flight token refresh and suspends token
    /// operations (before an erase) until `resumeTokenOperations()`.
    func invalidateAllTokenOperations() {
        coordinator?.invalidateAll()
    }

    /// Resumes token operations once an erase has wiped the Keychain.
    func resumeTokenOperations() {
        coordinator?.resumeTokenOperations()
    }

    /// Removes `email`'s token and revokes it at Google (best effort). Without
    /// a bundled client only the remote revoke is skipped: the local token is
    /// always deleted.
    func disconnect(_ email: String) async {
        if let coordinator {
            // The coordinator deletes the token *before* awaiting the revoke;
            // never delete again afterward, because by then the user may have
            // signed in again and the stored token is the replacement.
            await coordinator.disconnect(email)
            return
        }
        guard let tokenStore else { return }
        do {
            try tokenStore.deleteToken(for: email)
        } catch {
            logger.error("Couldn't remove a Google token from the Keychain: \(error.localizedDescription)")
        }
    }

    /// Deletes and revokes the grant from one authorization, only while it is
    /// still the stored one and no newer sign-in could be harmed by the
    /// revoke (see `GmailAuthCoordinator.discard(_:)`).
    func discard(_ authorization: GmailAuthorization) async {
        await coordinator?.discard(authorization)
    }

    /// Deletes `email`'s local token and returns it for rollback; throws when
    /// the Keychain delete fails. Works without a bundled client.
    func removeLocalToken(_ email: String) throws -> OAuthToken? {
        if let coordinator { return try coordinator.removeLocalToken(for: email) }
        guard let tokenStore else { return nil }
        let token = try tokenStore.loadToken(for: email)
        // Decoding is only needed for rollback, not for deleting the raw entry.
        try tokenStore.deleteToken(for: email)
        return token
    }

    /// Puts back a token taken by `removeLocalToken(_:)`.
    func restoreLocalToken(_ token: OAuthToken, for email: String) throws {
        if let coordinator {
            try coordinator.restoreLocalToken(token, for: email)
        } else {
            try tokenStore?.saveToken(token, for: email)
        }
    }

    /// Registers a best-effort remote revoke before returning (skipped without a client).
    @discardableResult
    func revokeRemovedToken(_ token: OAuthToken) -> Task<Void, Never>? {
        coordinator?.revokeRemovedToken(token)
    }

    /// Clears a failed attempt's message (e.g. when the user edits the form).
    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }
}

/// A `MailProvider` decorator that turns the `GoogleMailCredential.marker`
/// into a live XOAUTH2 access token for every session (item 104). App-password
/// credentials pass through untouched.
struct GoogleOAuthMailProvider: MailProvider {
    let base: MailProvider
    let auth: GoogleMailAuthService

    /// What the user signed in with, for failure details (the same decorator
    /// serves the Microsoft stack, item 31).
    private var isMicrosoft: Bool { auth.credentialMarker == MicrosoftMailCredential.marker }
    private var providerLabel: String { isMicrosoft ? "Microsoft" : "Google" }

    func resolved(_ credentials: MailAccountCredentials) async throws -> MailAccountCredentials {
        try await resolvedWithGrant(credentials).credentials
    }

    /// Resolves the credentials and, for a Google-signed-in mailbox whose
    /// token this call fetched, returns the grant generation that token
    /// belongs to (nil otherwise).
    private func resolvedWithGrant(
        _ credentials: MailAccountCredentials
    ) async throws -> (credentials: MailAccountCredentials, grant: GmailAuthCoordinator.TokenGeneration?) {
        guard credentials.appPassword == auth.credentialMarker,
              (credentials.oauthAccessToken ?? "").isEmpty else {
            return (credentials, nil)
        }
        let token: String
        let grant: GmailAuthCoordinator.TokenGeneration
        do {
            (token, grant) = try await auth.accessTokenWithGrant(for: credentials.email)
        } catch GmailAuthError.superseded {
            // The grant changed mid-refresh twice over: retry on the next poll,
            // never pause the mailbox as an auth failure.
            throw MailError.connectionFailed("\(providerLabel) sign-in changed while refreshing; will retry.")
        } catch let error as GmailAuthError {
            throw MailError.authenticationFailed(Self.detail(for: error, microsoft: isMicrosoft))
        } catch OAuthError.temporarilyUnavailable(let status) {
            // Google outage or throttling: the grant is fine, so retry later
            // instead of pausing the mailbox as an auth failure.
            throw MailError.connectionFailed("Couldn't refresh \(providerLabel) sign-in right now (HTTP \(status)).")
        } catch let error as OAuthError {
            throw MailError.authenticationFailed("\(providerLabel) sign-in failed: \(error)")
        } catch {
            // Token endpoint unreachable (offline, DNS, TLS): transient, retry later.
            throw MailError.connectionFailed("Couldn't refresh \(providerLabel) sign-in. (\(error.localizedDescription))")
        }
        var resolved = credentials
        resolved.oauthAccessToken = token
        return (resolved, grant)
    }

    static func detail(for error: GmailAuthError, microsoft: Bool = false) -> String {
        let prefix = microsoft ? MicrosoftMailCredential.failurePrefix : GoogleMailCredential.failurePrefix
        switch error {
        case .notConfigured:
            return "\(prefix) isn't available in this build — reconnect with an app password."
        default:
            return microsoft ? MicrosoftMailCredential.reauthorizationDetail : GoogleMailCredential.reauthorizationDetail
        }
    }

    /// Runs `operation` with resolved credentials, rewording a server-side
    /// XOAUTH2 rejection so it never reads as an app-password problem.
    ///
    /// A rejection of a token whose grant was replaced (the user signed in
    /// with Google again) or disconnected while the operation was out says
    /// nothing about the current grant: it is reported as a transient
    /// connection failure, so the next poll retries with the current token
    /// instead of pausing a mailbox that was just reauthorized.
    private func run<T>(
        _ credentials: MailAccountCredentials,
        classifyFreshIMAPFailure: Bool = false,
        _ operation: (MailAccountCredentials) async throws -> T
    ) async throws -> T {
        let (resolved, grant) = try await resolvedWithGrant(credentials)
        do {
            return try await operation(resolved)
        } catch MailError.authenticationFailed(let detail) where credentials.appPassword == auth.credentialMarker {
            if let grant, await auth.isGrantSuperseded(grant, for: credentials.email) {
                throw MailError.connectionFailed("\(providerLabel) sign-in changed during this mail session; will retry.")
            }
            let service = isMicrosoft ? "Outlook" : "Gmail"
            let prefix = isMicrosoft ? MicrosoftMailCredential.failurePrefix : GoogleMailCredential.failurePrefix
            let rejected = MailError.authenticationFailed("\(prefix) was rejected by \(service). (\(detail))")
            // IMAP turned off for the mailbox rejects even a brand-new token the
            // same way an expired grant would (item 31, T31-7).
            guard isMicrosoft, classifyFreshIMAPFailure else { throw rejected }
            let age = await auth.signInAge(for: credentials.email)
            throw MailboxProtocolMapping.classifyIMAPAuthenticationFailure(rejected, tokenAge: age)
        }
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        try await run(credentials, classifyFreshIMAPFailure: true) { try await base.verifyConnection($0) }
    }

    func verifyAndDiscover(_ credentials: MailAccountCredentials) async throws -> MailboxNaming? {
        try await run(credentials, classifyFreshIMAPFailure: true) { try await base.verifyAndDiscover($0) }
    }

    func probeSMTPAuthentication(_ credentials: MailAccountCredentials) async throws {
        try await run(credentials) { try await base.probeSMTPAuthentication($0) }
    }

    func fetchRecentMessages(_ credentials: MailAccountCredentials, mailbox: Mailbox, limit: Int) async throws -> [MailMessage] {
        try await run(credentials) { try await base.fetchRecentMessages($0, mailbox: mailbox, limit: limit) }
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, uid: UInt32, expectedUIDValidity: UInt32?
    ) async throws -> Data {
        try await run(credentials) {
            try await base.fetchBodyText($0, mailbox: mailbox, uid: uid, expectedUIDValidity: expectedUIDValidity)
        }
    }

    func fetchHeaderFields(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, uid: UInt32, expectedUIDValidity: UInt32?
    ) async throws -> MailHeaderFields {
        try await run(credentials) {
            try await base.fetchHeaderFields($0, mailbox: mailbox, uid: uid, expectedUIDValidity: expectedUIDValidity)
        }
    }

    func searchMessages(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, criteria: MailSearchCriteria, offset: Int, limit: Int
    ) async throws -> MailSearchResult {
        try await run(credentials) {
            try await base.searchMessages($0, mailbox: mailbox, criteria: criteria, offset: offset, limit: limit)
        }
    }

    func fetchMessagePage(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, offset: Int, limit: Int, snapshotMessageCount: Int?
    ) async throws -> MailSearchResult {
        try await run(credentials) {
            try await base.fetchMessagePage(
                $0, mailbox: mailbox, offset: offset, limit: limit, snapshotMessageCount: snapshotMessageCount
            )
        }
    }

    func previewBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        sampleLimit: Int,
        selectionCap: Int
    ) async throws -> MailBulkPreview {
        try await run(credentials) {
            try await base.previewBulkCleanup(
                $0, mailbox: mailbox, criteria: criteria, sampleLimit: sampleLimit, selectionCap: selectionCap
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selection: MailBulkSelection?,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> MailBulkResult {
        try await run(credentials) {
            try await base.applyBulkCleanup(
                $0, mailbox: mailbox, criteria: criteria, action: action,
                selection: selection, selectionCap: selectionCap, onProgress: onProgress
            )
        }
    }

    func appendMessage(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, rfc822: Data, flags: [MailFlag]
    ) async throws {
        try await run(credentials) { try await base.appendMessage($0, mailbox: mailbox, rfc822: rfc822, flags: flags) }
    }

    func sendMessage(_ credentials: MailAccountCredentials, rfc822: Data, envelope: SMTPEnvelope) async throws {
        try await run(credentials) { try await base.sendMessage($0, rfc822: rfc822, envelope: envelope) }
    }
}
