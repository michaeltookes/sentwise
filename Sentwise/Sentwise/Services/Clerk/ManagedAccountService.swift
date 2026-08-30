import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedAccountService")

/// The non-secret account identity AppState persists after a successful managed
/// sign-in. `displayIdentifier` is for UI copy; `accountIdentifier` is for
/// quota/alert scoping and never falls back to display text.
struct ManagedAccountSignInResult: Sendable, Equatable {
    let displayIdentifier: String?
    let accountIdentifier: String
}

/// Orchestrates the managed-inference account (backlog 56a): the Clerk email-code
/// sign-in, secure storage of the device/session credentials, and on-demand
/// minting of the short-lived session tokens the `sentwise-service` proxy verifies.
///
/// An `actor` so it is safely `Sendable` and can be used as the
/// `ManagedSessionProviding` for `LLMService` from any isolation context, while
/// its mutable in-progress sign-in state stays serialized. `AppState` (main
/// actor) drives it via `await`.
actor ManagedAccountService: ManagedSessionProviding {
    private let secrets: SecretStore
    /// Internal so the OAuth flow in the split `+OAuth` extension can reach it.
    let clerk: ClerkClient
    private static let invalidatedCredentialsMarkerValue = "1"

    /// In-progress sign-in handle (transient — only valid between `startSignIn`
    /// and `completeSignIn`).
    private var pendingSignIn: ClerkSignInHandle?
    /// In-progress OAuth (Google) sign-in handle (transient — only valid between
    /// `startGoogleSignIn` and `completeGoogleSignIn`). Internal so the OAuth flow,
    /// which lives in a split extension file, can drive it.
    var pendingOAuthSignIn: ClerkOAuthHandle?
    /// Changes whenever the stored account identity is cleared or replaced.
    var authenticationGeneration = 0
    /// Set after the server rejects credentials that may still be present in
    /// Keychain. This keeps the current process logically signed out even if
    /// cleanup cannot remove every stale value.
    var areStoredCredentialsInvalidated = false
    /// Latest client-token rotation from an in-progress reauthentication after
    /// stored credentials were invalidated. This is deliberately separate from
    /// the rejected session credential identity.
    private var reauthenticationClientToken: String?
    /// Clerk rotates the client token on every mint, so only one mint may be in
    /// flight at a time. Actor reentrancy alone is not enough because the actor is
    /// released while the network request is suspended.
    var isMintingSessionToken = false
    var mintWaiters: [CheckedContinuation<Void, Never>] = []

    init(secrets: SecretStore, clerk: ClerkClient = ClerkClient()) {
        self.secrets = secrets
        self.clerk = clerk
        self.areStoredCredentialsInvalidated = secrets.hasValue(for: .managedCredentialsInvalidated)
        self.reauthenticationClientToken = ((try? secrets.value(for: .managedReauthenticationClientToken)) ?? nil)
    }

    // MARK: - Sign-in

    /// True when a device token and session id are both stored — i.e. the user
    /// has a usable managed account.
    var isSignedIn: Bool {
        !areStoredCredentialsInvalidated && storedClientToken != nil && storedSessionID != nil
    }

    /// Begins email-code sign-in and sends the OTP. The device (client) token is
    /// persisted immediately so a rotated token survives even if the user quits
    /// before entering the code.
    func startSignIn(email: String) async throws {
        let existingClientToken = signInClientTokenForCurrentCredentialState()
        clearPendingSignInHandles()
        let created: ClerkSignInHandle
        do {
            created = try await clerk.createEmailCodeSignIn(email: email, clientToken: existingClientToken)
        } catch let error as ClerkError {
            persistClientTokenBestEffort(error.clientToken, context: "after failed sign-in creation")
            throw error
        }
        persistClientTokenBestEffort(created.clientToken, context: "after creating sign-in")

        do {
            let prepared = try await clerk.prepareEmailCode(for: created)
            pendingSignIn = prepared
            persistClientTokenBestEffort(prepared.clientToken, context: "after preparing sign-in")
        } catch let error as ClerkError {
            persistClientTokenBestEffort(error.clientToken, context: "after failed sign-in prepare")
            throw error
        }
    }

    /// Completes sign-in with the OTP code. On success stores the session id and
    /// the latest device token, then verifies the credentials end-to-end by
    /// minting one session token.
    @discardableResult
    func completeSignIn(code: String) async throws -> ManagedAccountSignInResult {
        guard let pending = pendingSignIn else {
            throw ClerkError.malformedResponse("no sign-in in progress")
        }
        let verified: ClerkVerifiedSession
        do {
            verified = try await clerk.verifyEmailCode(
                signInId: pending.signInId,
                code: code,
                clientToken: pending.clientToken,
                flow: pending.flow
            )
        } catch let error as ClerkError {
            updatePendingSignIn(pending, clientToken: error.clientToken)
            throw error
        }

        updatePendingSignIn(pending, clientToken: verified.clientToken)
        // Prove the credentials can mint a token before storing the session.
        guard isPendingSignIn(pending) else {
            throw ClerkError.malformedResponse("no sign-in in progress")
        }
        let minted = try await mintSessionToken(
            sessionID: verified.sessionId,
            clientToken: verified.clientToken,
            preserveFailureClientToken: .pending(pending)
        )
        guard isPendingSignIn(pending) else {
            throw ClerkError.malformedResponse("no sign-in in progress")
        }
        updatePendingSignIn(pending, clientToken: minted.clientToken)
        guard isPendingSignIn(pending) else {
            throw ClerkError.malformedResponse("no sign-in in progress")
        }
        let result = ManagedAccountSignInResult(
            displayIdentifier: verified.identifier,
            accountIdentifier: Self.accountIdentifier(userID: minted.userID, sessionID: verified.sessionId)
        )
        try finalizeVerifiedSession(sessionID: verified.sessionId, clientToken: minted.clientToken)
        return result
    }

    static func accountIdentifier(userID: String?, sessionID: String) -> String {
        let normalizedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedUserID, !normalizedUserID.isEmpty {
            return "clerk-user:\(normalizedUserID)"
        }
        return "clerk-session:\(sessionID)"
    }

    /// Cancels any in-progress email-code or browser-based sign-in. Rotated client
    /// tokens stay persisted because Clerk treats them as the current device token,
    /// not as proof that the sign-in should still complete.
    func cancelSignIn() {
        clearPendingSignInHandles()
    }

    func clearPendingSignInHandles() {
        pendingSignIn = nil
        pendingOAuthSignIn = nil
        clearPendingOAuthSignInIDBestEffort(context: "after cancelling sign-in")
    }

    /// Persists a freshly verified session and clears all in-progress/invalidation
    /// state. Shared by the email-code and OAuth completion paths.
    func finalizeVerifiedSession(sessionID: String, clientToken: String) throws {
        try persistClientToken(clientToken)
        try persistSessionID(sessionID)
        try clearCredentialInvalidationMarker()
        clearReauthenticationClientTokenBestEffort(context: "after sign-in")
        areStoredCredentialsInvalidated = false
        reauthenticationClientToken = nil
        authenticationGeneration &+= 1
        pendingSignIn = nil
        pendingOAuthSignIn = nil
        clearPendingOAuthSignInIDBestEffort(context: "after sign-in")
    }

    /// Signs out: clears the stored device token and session id. Local mail data
    /// is untouched.
    func signOut() throws {
        let wasSignedIn = isSignedIn
        pendingSignIn = nil
        pendingOAuthSignIn = nil
        reauthenticationClientToken = nil
        var firstError: Error?
        do {
            try secrets.remove(.managedClientToken)
        } catch {
            firstError = error
        }
        do {
            try secrets.remove(.managedSessionID)
        } catch {
            firstError = firstError ?? error
        }
        clearPendingOAuthSignInIDBestEffort(context: "after sign-out")
        if wasSignedIn && !isSignedIn {
            authenticationGeneration &+= 1
        }
        if !hasStoredManagedCredential {
            areStoredCredentialsInvalidated = false
            clearCredentialInvalidationMarkerBestEffort(context: "after sign-out")
        }
        clearReauthenticationClientTokenBestEffort(context: "after sign-out")
        if let firstError {
            throw firstError
        }
    }

    // MARK: - ManagedSessionProviding

    /// Mints a fresh, short-lived session JWT for the proxy. Rotates and re-stores
    /// the device token that Clerk returns, surfacing persistence failures so the
    /// rotated token is never silently lost. Throws `LLMError.managedNotSignedIn`
    /// when there is no stored account.
    func currentSessionToken() async throws -> String {
        (try await currentManagedSession()).jwt
    }

    func currentManagedSession() async throws -> ManagedSessionToken {
        await beginMintTurn()
        defer { endMintTurn() }
        return try await mintCurrentManagedSession()
    }

    func invalidateSession() async {
        let wasSignedIn = isSignedIn
        pendingSignIn = nil
        pendingOAuthSignIn = nil
        reauthenticationClientToken = nil
        areStoredCredentialsInvalidated = true
        persistCredentialInvalidationMarker()
        clearReauthenticationClientTokenBestEffort(context: "after invalidation")
        if wasSignedIn {
            authenticationGeneration &+= 1
        }
        do {
            try secrets.remove(.managedClientToken)
        } catch {
            logger.error("Failed to remove invalid managed client token: \(error.localizedDescription)")
        }
        do {
            try secrets.remove(.managedSessionID)
        } catch {
            logger.error("Failed to remove invalid managed session id: \(error.localizedDescription)")
        }
        clearPendingOAuthSignInIDBestEffort(context: "after invalidation")
        if !hasStoredManagedCredential {
            clearCredentialInvalidationMarkerBestEffort(context: "after invalidation cleanup")
        }
    }

    func invalidateSession(matching credentialIdentity: String?) async {
        guard let credentialIdentity else {
            await invalidateSession()
            return
        }
        guard currentCredentialIdentity == credentialIdentity else { return }
        await invalidateSession()
    }

    private func mintCurrentManagedSession() async throws -> ManagedSessionToken {
        while true {
            guard !areStoredCredentialsInvalidated,
                  let clientToken = storedClientToken,
                  let sessionID = storedSessionID
            else {
                throw LLMError.managedNotSignedIn
            }
            let generation = authenticationGeneration
            do {
                let minted = try await mintSessionToken(
                    sessionID: sessionID,
                    clientToken: clientToken,
                    preserveFailureClientToken: .stored(generation: generation)
                )
                switch credentialState(generation: generation, sessionID: sessionID, clientToken: clientToken) {
                case .current:
                    try persistClientToken(minted.clientToken)
                    return ManagedSessionToken(
                        jwt: minted.jwt,
                        credentialIdentity: credentialIdentity(generation: generation, sessionID: sessionID)
                    )
                case .rotated:
                    continue
                case .signedOutOrReplaced:
                    throw LLMError.managedNotSignedIn
                }
            } catch LLMError.managedNotSignedIn {
                switch credentialState(generation: generation, sessionID: sessionID, clientToken: clientToken) {
                case .current:
                    // Device token or session no longer valid — force a fresh sign-in.
                    await invalidateSession()
                    throw LLMError.managedNotSignedIn
                case .rotated:
                    continue
                case .signedOutOrReplaced:
                    throw LLMError.managedNotSignedIn
                }
            }
        }
    }

    // MARK: - Storage

    var storedClientToken: String? {
        let value = (try? secrets.value(for: .managedClientToken)) ?? nil
        return (value?.isEmpty == false) ? value : nil
    }

    var storedSessionID: String? {
        let value = (try? secrets.value(for: .managedSessionID)) ?? nil
        return (value?.isEmpty == false) ? value : nil
    }

    private var hasStoredManagedCredential: Bool {
        storedClientToken != nil || storedSessionID != nil
    }

    func signInClientTokenForCurrentCredentialState() -> String {
        if areStoredCredentialsInvalidated {
            return reauthenticationClientToken ?? ""
        }
        return storedClientToken ?? ""
    }

    func persistClientToken(_ token: String) throws {
        guard !token.isEmpty else { return }
        try secrets.set(token, for: .managedClientToken)
    }

    func persistClientTokenBestEffort(_ token: String?, context: String) {
        guard let token, !token.isEmpty else { return }
        persistReauthenticationClientTokenIfNeeded(token)
        do {
            try persistClientToken(token)
        } catch {
            logger.error("Failed to persist Clerk client token \(context): \(error.localizedDescription)")
        }
    }

    private func persistSessionID(_ sessionID: String) throws {
        try secrets.set(sessionID, for: .managedSessionID)
    }

    private func persistCredentialInvalidationMarker() {
        do {
            try secrets.set(Self.invalidatedCredentialsMarkerValue, for: .managedCredentialsInvalidated)
        } catch {
            logger.error("Failed to persist managed credential invalidation marker: \(error.localizedDescription)")
        }
    }

    private func clearCredentialInvalidationMarker() throws {
        try secrets.remove(.managedCredentialsInvalidated)
    }

    private func clearCredentialInvalidationMarkerBestEffort(context: String) {
        do {
            try clearCredentialInvalidationMarker()
        } catch {
            logger.error("Failed to clear managed credential invalidation marker \(context): \(error.localizedDescription)")
        }
    }

    private func persistReauthenticationClientTokenIfNeeded(_ token: String) {
        guard areStoredCredentialsInvalidated, !token.isEmpty else { return }
        reauthenticationClientToken = token
        do {
            try secrets.set(token, for: .managedReauthenticationClientToken)
        } catch {
            logger.error("Failed to persist managed reauthentication client token: \(error.localizedDescription)")
        }
    }

    private func clearReauthenticationClientToken() throws {
        try secrets.remove(.managedReauthenticationClientToken)
    }

    private func clearReauthenticationClientTokenBestEffort(context: String) {
        do {
            try clearReauthenticationClientToken()
        } catch {
            logger.error("Failed to clear managed reauthentication client token \(context): \(error.localizedDescription)")
        }
    }

    private var storedPendingOAuthSignInID: String? {
        let value = (try? secrets.value(for: .managedOAuthSignInID)) ?? nil
        return (value?.isEmpty == false) ? value : nil
    }

    func pendingOAuthSignInHandle() -> ClerkOAuthHandle? {
        if let pendingOAuthSignIn {
            return pendingOAuthSignIn
        }
        guard let signInID = storedPendingOAuthSignInID else { return nil }
        let clientToken = signInClientTokenForCurrentCredentialState()
        guard !clientToken.isEmpty else { return nil }
        return ClerkOAuthHandle(
            signInId: signInID,
            externalRedirectURL: URL(string: "about:blank")!,
            clientToken: clientToken
        )
    }

    func persistPendingOAuthSignInIDBestEffort(_ signInID: String, context: String) {
        guard !signInID.isEmpty else { return }
        do {
            try secrets.set(signInID, for: .managedOAuthSignInID)
        } catch {
            logger.error("Failed to persist Clerk OAuth sign-in id \(context): \(error.localizedDescription)")
        }
    }

    private func clearPendingOAuthSignInID() throws {
        try secrets.remove(.managedOAuthSignInID)
    }

    private func clearPendingOAuthSignInIDBestEffort(context: String) {
        do {
            try clearPendingOAuthSignInID()
        } catch {
            logger.error("Failed to clear Clerk OAuth sign-in id \(context): \(error.localizedDescription)")
        }
    }

    private func isPendingSignIn(_ handle: ClerkSignInHandle) -> Bool {
        pendingSignIn?.signInId == handle.signInId && pendingSignIn?.flow == handle.flow
    }

    func updatePendingSignIn(_ handle: ClerkSignInHandle, clientToken: String?) {
        guard let clientToken, !clientToken.isEmpty, isPendingSignIn(handle) else { return }
        pendingSignIn = ClerkSignInHandle(
            signInId: handle.signInId,
            emailAddressId: handle.emailAddressId,
            clientToken: clientToken,
            flow: handle.flow
        )
        persistReauthenticationClientTokenIfNeeded(clientToken)
        do {
            try persistClientToken(clientToken)
        } catch {
            logger.error("Failed to persist Clerk client token after sign-in attempt: \(error.localizedDescription)")
        }
    }

    func isPendingOAuthSignIn(_ handle: ClerkOAuthHandle) -> Bool {
        if let pendingOAuthSignIn {
            return pendingOAuthSignIn.signInId == handle.signInId
        }
        return storedPendingOAuthSignInID == handle.signInId
    }

    func updatePendingOAuthSignIn(_ handle: ClerkOAuthHandle, clientToken: String?) {
        guard let clientToken, !clientToken.isEmpty, isPendingOAuthSignIn(handle) else { return }
        pendingOAuthSignIn = ClerkOAuthHandle(
            signInId: handle.signInId,
            externalRedirectURL: handle.externalRedirectURL,
            clientToken: clientToken
        )
        persistReauthenticationClientTokenIfNeeded(clientToken)
        do {
            try persistClientToken(clientToken)
        } catch {
            logger.error("Failed to persist Clerk client token after OAuth sign-in attempt: \(error.localizedDescription)")
        }
    }
}
