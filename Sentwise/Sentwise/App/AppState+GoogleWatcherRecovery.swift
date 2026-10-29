import Foundation
import SentwiseMail

extension AppState {
    /// Whether a watcher failure is the Google-signed-in mailbox rejecting its
    /// grant (a poll fetch, or a draft's body fetch), which a successful
    /// "Sign in with Google again" fixes. AI-provider auth failures (managed
    /// sign-in, API key) are not: they recover through their own flow.
    static func isGoogleMailboxAuthFailure(_ error: Error, credentials: MailAccountCredentials) -> Bool {
        guard GoogleMailCredential.isGoogleSignIn(credentials)
                || MicrosoftMailCredential.isMarker(credentials.appPassword),
              case MailError.authenticationFailed = error else { return false }
        return true
    }

    /// Successful mailbox verification has adopted this account as the focused
    /// mailbox. Resume only an auth-induced pause, never a manual pause or stop.
    func resumeInboxWatchingAfterGoogleReauth(email: String) {
        guard activeAccountUsesGoogleSignIn || activeAccountUsesMicrosoftSignIn,
              SavedMailAccount.normalizedEmail(mailEmail) == SavedMailAccount.normalizedEmail(email),
              resumeWatchingAfterGoogleReauth,
              watchStatus == .paused else { return }
        resumeWatchingAfterGoogleReauth = false
        watchError = nil
        if canWatch {
            startWatching()
        } else {
            // Mail is healthy again; retain the user's watch intent until the
            // AI provider or subscription becomes ready through its normal flow.
            resumeWatchingAfterManagedReauth = true
        }
    }
}

// MARK: - Reconnecting a background Google mailbox

extension AppState {
    /// Whether the saved mailbox `account` is a background Google mailbox
    /// whose watcher paused on a Google auth failure (expired or revoked
    /// grant). Switching to it can't help, because the switch verifies the
    /// dead grant and switches back, so Settings offers "Sign in with Google
    /// again" on its row instead. A manual pause clears the recovery intent
    /// and with it this offer, matching how the focused mailbox recovers.
    func savedAccountNeedsGoogleReauth(_ account: SavedMailAccount) -> Bool {
        guard isGoogleSignInAvailable, !isActiveAccount(account),
              let connected = backgroundConnectedAccount(email: account.email),
              GoogleMailCredential.isGoogleSignIn(connected.credentials) else { return false }
        return connected.resumeWatchingAfterGoogleReauth
    }

    /// A saved background Microsoft mailbox whose watcher paused on a sign-in
    /// failure and can be resumed by signing in again.
    func savedAccountNeedsMicrosoftReauth(_ account: SavedMailAccount) -> Bool {
        guard isMicrosoftSignInAvailable, !isActiveAccount(account),
              let connected = backgroundConnectedAccount(email: account.email),
              MicrosoftMailCredential.isMarker(connected.credentials.appPassword) else { return false }
        return connected.resumeWatchingAfterGoogleReauth
    }
}
