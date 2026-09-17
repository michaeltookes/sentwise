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

    func handlePollFetchFailure(
        _ error: Error,
        account: ConnectedMailAccount? = nil,
        localDataGeneration: UInt64
    ) {
        guard isCurrentLocalDataGeneration(localDataGeneration) else { return }
        handlePollFetchFailure(error, account: account)
    }
}
