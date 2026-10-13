import Combine
import Foundation
import SentwiseMail

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
/// the feature off everywhere. Available on every plan tier (item 104 — tier
/// placement pending owner confirmation; no gate is applied here).
@MainActor
final class GoogleMailAuthService: ObservableObject {
    @Published private(set) var phase: GmailAuthPhase = .idle

    private(set) var coordinator: GmailAuthCoordinator?
    private var signInTask: Task<GmailAuthorization, Error>?

    init(coordinator: GmailAuthCoordinator?) {
        install(coordinator)
    }

    /// The production service: the bundled client from Info.plist (if any),
    /// tokens in `secrets`.
    static func live(secrets: SecretStore) -> GoogleMailAuthService {
        let coordinator = GoogleOAuthClientConfiguration.bundled().map { client in
            GmailAuthCoordinator(
                client: client,
                store: GmailAuthStore(secrets: secrets),
                tokenService: OAuthTokenService(transport: URLSessionTransport())
            )
        }
        return GoogleMailAuthService(coordinator: coordinator)
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
        defer { signInTask = nil }
        return try await task.value
    }

    /// Abandons a sign-in that is waiting on the browser.
    func cancelSignIn() {
        signInTask?.cancel()
    }

    func isConnected(_ email: String) -> Bool {
        coordinator?.isConnected(email) ?? false
    }

    func accessToken(for email: String) async throws -> String {
        guard let coordinator else { throw GmailAuthError.notConfigured }
        return try await coordinator.validAccessToken(for: email)
    }

    /// Removes `email`'s token and revokes it at Google (best effort).
    func disconnect(_ email: String) async {
        await coordinator?.disconnect(email)
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

    func resolved(_ credentials: MailAccountCredentials) async throws -> MailAccountCredentials {
        guard GoogleMailCredential.isGoogleSignIn(credentials),
              (credentials.oauthAccessToken ?? "").isEmpty else {
            return credentials
        }
        let token: String
        do {
            token = try await auth.accessToken(for: credentials.email)
        } catch let error as GmailAuthError {
            throw MailError.authenticationFailed(Self.detail(for: error))
        } catch let error as OAuthError {
            throw MailError.authenticationFailed("\(GoogleMailCredential.failurePrefix) failed: \(error)")
        } catch {
            // Token endpoint unreachable (offline, DNS, TLS): transient, retry later.
            throw MailError.connectionFailed("Couldn't refresh Google sign-in. (\(error.localizedDescription))")
        }
        var resolved = credentials
        resolved.oauthAccessToken = token
        return resolved
    }

    static func detail(for error: GmailAuthError) -> String {
        switch error {
        case .notConfigured:
            return "\(GoogleMailCredential.failurePrefix) isn't available in this build — reconnect with an app password."
        default:
            return GoogleMailCredential.reauthorizationDetail
        }
    }

    /// Runs `operation` with resolved credentials, rewording a server-side
    /// XOAUTH2 rejection so it never reads as an app-password problem.
    private func run<T>(
        _ credentials: MailAccountCredentials,
        _ operation: (MailAccountCredentials) async throws -> T
    ) async throws -> T {
        let resolved = try await resolved(credentials)
        do {
            return try await operation(resolved)
        } catch MailError.authenticationFailed(let detail) where GoogleMailCredential.isGoogleSignIn(credentials) {
            throw MailError.authenticationFailed("\(GoogleMailCredential.failurePrefix) was rejected by Gmail. (\(detail))")
        }
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        try await run(credentials) { try await base.verifyConnection($0) }
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
