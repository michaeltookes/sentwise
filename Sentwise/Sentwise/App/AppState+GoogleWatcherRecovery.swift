import Foundation
import SentwiseMail

extension AppState {
    /// Whether a watcher failure is the Google-signed-in mailbox rejecting its
    /// grant (a poll fetch, or a draft's body fetch), which a successful
    /// "Sign in with Google again" fixes. AI-provider auth failures (managed
    /// sign-in, API key) are not: they recover through their own flow.
    static func isGoogleMailboxAuthFailure(_ error: Error, credentials: MailAccountCredentials) -> Bool {
        guard GoogleMailCredential.isGoogleSignIn(credentials),
              case MailError.authenticationFailed = error else { return false }
        return true
    }

    /// Successful mailbox verification has adopted this account as the focused
    /// mailbox. Resume only an auth-induced pause, never a manual pause or stop.
    func resumeInboxWatchingAfterGoogleReauth(email: String) {
        guard activeAccountUsesGoogleSignIn,
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
