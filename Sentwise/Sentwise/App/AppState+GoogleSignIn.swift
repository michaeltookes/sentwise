import Foundation
import os
import SentwiseMail

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "GoogleSignIn")

/// "Sign in with Google" for Gmail and Google Workspace mailboxes (item 104).
///
/// The browser flow yields a token stored per account; the mailbox is then
/// verified and adopted through the exact same `testConnection(with:)` path as
/// an app password, carrying `GoogleMailCredential.marker` in the per-account
/// credential slot. App passwords stay the fallback and the only path for
/// non-Gmail providers. Offered on every plan tier.
extension AppState {

    /// The Google sign-in service plus the mail provider wrapped so Google
    /// mailboxes authenticate with XOAUTH2 (used once, by `AppState.init`).
    static func makeMailStack(
        base: MailProvider?,
        secrets: SecretStore
    ) -> (GoogleMailAuthService, GoogleMailAuthService, MailProvider) {
        let google = GoogleMailAuthService.live(secrets: secrets)
        let microsoft = GoogleMailAuthService.liveMicrosoft(secrets: secrets)
        let googleWrapped = GoogleOAuthMailProvider(base: base ?? LiveMailProvider.imap(), auth: google)
        // The same decorator serves Microsoft: it matches its own credential marker.
        return (google, microsoft, GoogleOAuthMailProvider(base: googleWrapped, auth: microsoft))
    }

    /// Whether this build can offer Google sign-in. Off when no client is
    /// bundled, and always off in Prowl hunt mode (no real browser/network).
    var isGoogleSignInAvailable: Bool {
        googleMailAuth.isAvailable && !ProwlHuntRuntime.current.isEnabled
    }

    /// Whether the focused, connected mailbox signed in with Google.
    var activeAccountUsesGoogleSignIn: Bool {
        isAccountConnected && GoogleMailCredential.isMarker(mailAppPassword)
    }

    /// Whether the saved mailbox `email` signed in with Google.
    func savedAccountUsesGoogleSignIn(_ email: String) -> Bool {
        let stored = (try? secrets.value(for: .mailAppPassword(email: email))) ?? nil
        return stored.map(GoogleMailCredential.isMarker) ?? false
    }

    /// The connect method to lead with for the address/host being entered.
    func recommendedConnectMethod(email: String, host: String) -> MailConnectMethod {
        MailConnectMethod.recommended(email: email, host: host, isGoogleSignInAvailable: isGoogleSignInAvailable)
    }

    /// Runs Google sign-in in the browser, then verifies and adopts the mailbox
    /// it authorized. Returns whether the mailbox is now connected.
    ///
    /// - Parameter loginHint: pre-selects an address on Google's chooser (the
    ///   email typed so far, or the saved account being reconnected).
    @discardableResult
    func connectWithGoogle(
        loginHint: String? = nil,
        requireHintMatch: Bool = false,
        messageSurface: TransientMessageSurface = .shared,
        shouldApplyResult: @escaping @MainActor (MailAccountCredentials) -> Bool = { _ in true }
    ) async -> Bool {
        setConnectionError(nil, for: messageSurface)
        clearWorkspaceAuthGuidance(for: messageSurface)
        guard isGoogleSignInAvailable else {
            setConnectionError(GmailAuthCoordinator.message(for: GmailAuthError.notConfigured), for: messageSurface)
            return false
        }
        guard !googleMailAuth.isSignInPending else { return false }
        // Supersedes an app-password test in flight; a later one supersedes this.
        let attempt = beginMailConnectionAttempt()
        // "Erase all local data" may run while the browser is open; a flow
        // started before the erase must never recreate tokens or reconnect.
        let localDataGeneration = localDataEraseGeneration
        // Likewise a saved mailbox removed while the browser is open stays removed.
        let removalMark = googleMailAuth.accountRemovalMark()
        // Closing/reopening Settings while the chooser is open starts a new
        // Settings session; this flow's result belongs to the old one.
        let settingsGeneration = settingsTransientMessageGeneration
        let isCurrentSurface: @MainActor () -> Bool = {
            self.isCurrentTransientMessageSurface(messageSurface, generation: settingsGeneration)
        }
        let isStale: @MainActor (String) -> Bool = { email in
            !self.isCurrentLocalDataGeneration(localDataGeneration)
                || self.googleMailAuth.wasAccountRemoved(email, since: removalMark)
        }

        let authorization: GmailAuthorization
        do {
            authorization = try await googleMailAuth.signIn(loginHint: loginHint, requireHintMatch: requireHintMatch)
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentLocalDataGeneration(localDataGeneration),
                  isCurrentMailConnectionAttempt(attempt), isCurrentSurface() else { return false }
            setConnectionError(GmailAuthCoordinator.message(for: error), for: messageSurface)
            return false
        }

        return await adoptGoogleAuthorization(
            authorization,
            attempt: attempt,
            isStale: isStale,
            messageSurface: messageSurface,
            shouldApplyResult: { isCurrentSurface() && shouldApplyResult($0) }
        )
    }

    /// Verifies and adopts the mailbox a finished browser flow authorized,
    /// unless the flow went stale (erase, removal, or a newer attempt).
    private func adoptGoogleAuthorization(
        _ authorization: GmailAuthorization,
        attempt: UInt64,
        isStale: @escaping @MainActor (String) -> Bool,
        messageSurface: TransientMessageSurface,
        shouldApplyResult: @escaping @MainActor (MailAccountCredentials) -> Bool
    ) async -> Bool {
        let email = authorization.email
        // Cleanup touches only this flow's own grant, never one a newer attempt stored.
        let dropThisGrant = { await self.googleMailAuth.discard(authorization) }
        guard !isStale(email) else {
            await dropThisGrant()
            return false
        }
        let wasGoogleConnected = savedAccountUsesGoogleSignIn(email)
        let credentials = GoogleMailCredential.credentials(email: email)
        guard isCurrentMailConnectionAttempt(attempt), shouldApplyResult(credentials) else {
            // Another connection attempt or Settings session started meanwhile
            // (or the caller no longer wants it): don't adopt this one.
            if !wasGoogleConnected { await dropThisGrant() }
            return false
        }
        let connected = await testConnection(
            with: credentials, messageSurface: messageSurface, attempt: attempt
        ) { !isStale(email) && shouldApplyResult($0) }
        guard !isStale(email) else {
            // Erased or removed mid-verification: whatever the outcome, keep no grant.
            await dropThisGrant()
            return false
        }
        if !connected && !wasGoogleConnected {
            // Never leave an orphaned grant behind for a mailbox that didn't connect.
            await dropThisGrant()
        }
        if connected {
            resumeInboxWatchingAfterGoogleReauth(email: email)
            logger.info("Mailbox connected with Google sign-in")
        }
        return connected
    }

    /// Starts a mailbox connection attempt (app password or Google),
    /// superseding the previous one: its result won't be committed, a pending
    /// Google sign-in is canceled, and the busy flag passes to the new attempt.
    func beginMailConnectionAttempt() -> UInt64 {
        isConnecting = false
        microsoftMailAuth.cancelSignIn()
        return googleMailAuth.beginConnectionAttempt()
    }

    func isCurrentMailConnectionAttempt(_ attempt: UInt64) -> Bool {
        googleMailAuth.isCurrentConnectionAttempt(attempt)
    }

    /// `shouldApplyResult`, but false once `attempt` has been superseded.
    func guardedByMailConnectionAttempt(
        _ attempt: UInt64,
        _ shouldApplyResult: @escaping @MainActor (MailAccountCredentials) -> Bool
    ) -> @MainActor (MailAccountCredentials) -> Bool {
        { self.isCurrentMailConnectionAttempt(attempt) && shouldApplyResult($0) }
    }

    /// Abandons a Google sign-in that is waiting on the browser.
    func cancelGoogleSignIn() {
        googleMailAuth.cancelSignIn()
    }

    /// Stops every in-flight Google operation before "Erase all local data"
    /// wipes the Keychain, so none can save a token afterward.
    func cancelGoogleOperationsForErase() {
        googleMailAuth.cancelSignIn()
        googleMailAuth.invalidateAllTokenOperations()
        microsoftMailAuth.cancelSignIn()
        microsoftMailAuth.invalidateAllTokenOperations()
    }

    /// Lifts the erase-time suspension once the Keychain has been wiped.
    func resumeGoogleOperationsAfterErase() {
        googleMailAuth.resumeTokenOperations()
        microsoftMailAuth.resumeTokenOperations()
    }

    /// Deletes a mailbox's OAuth token (Google or Microsoft, whichever service
    /// holds one; works without a configured client id) as a rollbackable step
    /// of removing the mailbox: done before the account record goes, so a
    /// Keychain failure aborts the removal instead of orphaning a refresh token.
    func removeGoogleTokenForAccountRemoval(_ email: String) throws -> GoogleTokenRemoval {
        let google = try googleMailAuth.removeLocalToken(email)
        do {
            return GoogleTokenRemoval(email: email, token: google, microsoftToken: try microsoftMailAuth.removeLocalToken(email))
        } catch {
            if let google { try? googleMailAuth.restoreLocalToken(google, for: email) }
            throw error
        }
    }

    /// Rolls back `removeGoogleTokenForAccountRemoval` when a later step fails.
    func restoreGoogleTokenAfterFailedRemoval(_ removal: GoogleTokenRemoval?) {
        guard let removal else { return }
        do {
            if let token = removal.token { try googleMailAuth.restoreLocalToken(token, for: removal.email) }
            if let token = removal.microsoftToken { try microsoftMailAuth.restoreLocalToken(token, for: removal.email) }
        } catch {
            logger.error("Couldn't restore an OAuth token after a failed removal: \(error.localizedDescription)")
        }
    }

    /// Takes the Google token of `email` as the first, rollbackable step of
    /// disconnecting it (only when it signed in with Google). Returns nil, with
    /// a Keychain error shown, when the delete fails and the caller must stop.
    func takeGoogleTokenForDisconnect(
        email: String,
        messageSurface: TransientMessageSurface
    ) -> GoogleTokenRemoval? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, savedAccountUsesGoogleSignIn(trimmed) || savedAccountUsesMicrosoftSignIn(trimmed) else {
            return GoogleTokenRemoval(email: trimmed, token: nil, microsoftToken: nil)
        }
        return takeGoogleToken(email: trimmed, messageSurface: messageSurface)
    }

    /// Takes the Google token when `newSecret` replaces a Google sign-in with
    /// an app password; same contract as `takeGoogleTokenForDisconnect`.
    func takeGoogleTokenForSwitch(
        email: String,
        previousSecret: String?,
        newSecret: String,
        messageSurface: TransientMessageSurface
    ) -> GoogleTokenRemoval? {
        guard let previousSecret else { return GoogleTokenRemoval(email: email, token: nil, microsoftToken: nil) }
        let previousIsGoogle = GoogleMailCredential.isMarker(previousSecret)
        let previousIsMicrosoft = MicrosoftMailCredential.isMarker(previousSecret)
        let newIsGoogle = GoogleMailCredential.isMarker(newSecret)
        let newIsMicrosoft = MicrosoftMailCredential.isMarker(newSecret)
        guard previousIsGoogle || previousIsMicrosoft else {
            return GoogleTokenRemoval(email: email, token: nil, microsoftToken: nil)
        }
        if !newIsGoogle && !newIsMicrosoft {
            return takeGoogleToken(email: email, messageSurface: messageSurface)
        }
        // OAuth to OAuth: same provider is a reauthentication (keep the fresh
        // token); a different provider drops only the previous provider's token.
        if previousIsGoogle && newIsMicrosoft {
            return takeOneToken(email: email, messageSurface: messageSurface) {
                GoogleTokenRemoval(email: email, token: try self.googleMailAuth.removeLocalToken(email), microsoftToken: nil)
            }
        }
        if previousIsMicrosoft && newIsGoogle {
            return takeOneToken(email: email, messageSurface: messageSurface) {
                GoogleTokenRemoval(email: email, token: nil, microsoftToken: try self.microsoftMailAuth.removeLocalToken(email))
            }
        }
        return GoogleTokenRemoval(email: email, token: nil, microsoftToken: nil)
    }

    private func takeOneToken(
        email: String,
        messageSurface: TransientMessageSurface,
        remove: () throws -> GoogleTokenRemoval
    ) -> GoogleTokenRemoval? {
        do {
            return try remove()
        } catch {
            setConnectionError(Self.keychainMessage(action: "remove", error: error), for: messageSurface)
            return nil
        }
    }

    private func takeGoogleToken(email: String, messageSurface: TransientMessageSurface) -> GoogleTokenRemoval? {
        do {
            return try removeGoogleTokenForAccountRemoval(email)
        } catch {
            setConnectionError(Self.keychainMessage(action: "remove", error: error), for: messageSurface)
            return nil
        }
    }

    /// Puts a taken token back after a later step of the operation failed.
    func rollBack(_ removal: GoogleTokenRemoval) {
        restoreGoogleTokenAfterFailedRemoval(removal)
    }

    /// Finishes a successful operation: revokes the taken token's grant.
    func complete(_ removal: GoogleTokenRemoval) {
        revokeRemovedGoogleToken(removal)
    }

    /// Revokes a removed mailbox's grant at Google (best effort, tracked).
    func revokeRemovedGoogleToken(_ removal: GoogleTokenRemoval?) {
        guard let removal else { return }
        if let token = removal.token { googleMailAuth.revokeRemovedToken(token) }
        if let token = removal.microsoftToken { microsoftMailAuth.revokeRemovedToken(token) }
    }

    /// A saved mailbox was removed: cancel/invalidate any Google sign-in that
    /// could otherwise restore it when the browser comes back.
    func noteGoogleAccountRemoved(_ email: String) {
        googleMailAuth.noteAccountRemoved(email)
        microsoftMailAuth.noteAccountRemoved(email)
    }
}

/// A Google token taken out of the Keychain as a rollbackable step (item 104).
struct GoogleTokenRemoval {
    let email: String
    let token: OAuthToken?
    let microsoftToken: OAuthToken?
}
