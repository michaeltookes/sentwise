import SentwiseMail
import Foundation

/// A mailbox connected concurrently alongside the focused account (item 99,
/// multi-account support). Each connected account has its own IMAP watcher and
/// its own connect/disconnect/health, so the watchers run in parallel and each
/// drafts in its own account's voice. The focused account remains the `AppState`
/// single-account fields; these runtimes cover the additional connected mailboxes.
@MainActor
final class ConnectedMailAccount: Identifiable {
    let email: String
    var host: String
    var port: Int
    /// Held in memory so the watcher and dispatch can build credentials without a
    /// Keychain read on every poll; the durable copy lives in the Keychain.
    var appPassword: String

    /// This account's independent watch state and health.
    var watchStatus: AppState.WatchStatus = .idle
    var watchError: String?
    /// Reentrancy guard so overlapping polls for this account can't double-process.
    var isPollingInbox = false
    /// Set when a managed license/auth refresh should restart this account's watcher.
    var resumeWatchingAfterManagedReauth = false

    /// This account's own poll loop. Nil until watching starts.
    var watcher: InboxWatcher?

    init(email: String, host: String, port: Int, appPassword: String) {
        self.email = email
        self.host = host
        self.port = port
        self.appPassword = appPassword
    }

    /// The stable account identity (normalized email), matching `SavedMailAccount.id`.
    var id: String { SavedMailAccount.normalizedEmail(email) }

    var credentials: MailAccountCredentials {
        MailAccountCredentials(email: email, appPassword: appPassword, host: host, port: port)
    }
}
