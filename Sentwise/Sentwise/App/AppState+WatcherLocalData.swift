import SentwiseMail
import Foundation

extension AppState {
    func prepareWatcherPoll(account: ConnectedMailAccount? = nil, localDataGeneration: UInt64) async -> Bool {
        await refreshManagedQuotaIfLicenseStatusStale()
        guard isCurrentLocalDataGeneration(localDataGeneration) else {
            DiagnosticLog.verbose("Inbox poll discarded; local data was purged")
            return false
        }
        guard canWatch(account: account) else {
            DiagnosticLog.verbose("Inbox poll paused; account or AI provider is unavailable")
            pauseWatching(
                account: account,
                resumeAfterManagedReauthentication: shouldResumeWatchingAfterManagedLicenseRecovery
            )
            return false
        }
        return true
    }

    func isCurrentWatcherPoll(
        localDataGeneration: UInt64,
        credentials: MailAccountCredentials,
        account: ConnectedMailAccount?
    ) -> Bool {
        guard isCurrentLocalDataGeneration(localDataGeneration) else { return false }
        if let account {
            return account.watchStatus == .watching
                && account.credentials == credentials
                && backgroundConnectedAccounts.contains { $0 === account }
        }
        return watchStatus == .watching
            && mailCredentials == credentials
            && isConnectedAccount(credentials)
    }

    /// Applies a poll's fetch failure, unless the poll is stale: local data was
    /// erased, or the mailbox no longer uses the credentials the poll fetched
    /// with (switched from Google sign-in to an app password, another account,
    /// or the watcher stopped). A stale failure says nothing about the current
    /// connection, so it never pauses it or asks for re-authorization.
    func handlePollFetchFailure(
        _ error: Error,
        account: ConnectedMailAccount? = nil,
        credentials: MailAccountCredentials,
        localDataGeneration: UInt64
    ) {
        guard isCurrentWatcherPoll(localDataGeneration: localDataGeneration, credentials: credentials, account: account) else {
            DiagnosticLog.verbose("Inbox poll failure discarded; account or watcher changed during fetch")
            return
        }
        handlePollFetchFailure(error, account: account)
    }
}
