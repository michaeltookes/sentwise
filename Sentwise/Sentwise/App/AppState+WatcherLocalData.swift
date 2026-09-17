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
        credentials: MailAccountCredentials
    ) -> Bool {
        // Multi-account (item 99): validate against the account whose poll is in
        // flight — focused or background — not just the focused account.
        isCurrentLocalDataGeneration(localDataGeneration)
            && isAccountWatching(credentials)
            && isConnectedAccount(credentials)
    }

    func handlePollFetchFailure(
        _ error: Error,
        account: ConnectedMailAccount? = nil,
        localDataGeneration: UInt64
    ) {
        guard isCurrentLocalDataGeneration(localDataGeneration) else { return }
        handlePollFetchFailure(error, account: account)
    }
}
