import Foundation

extension AppState {
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
