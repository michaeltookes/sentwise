import SentwiseMail
import Foundation

extension AppState {
    func prepareWatcherPoll(localDataGeneration: UInt64) async -> Bool {
        await refreshManagedQuotaIfLicenseStatusStale()
        guard isCurrentLocalDataGeneration(localDataGeneration) else {
            DiagnosticLog.verbose("Inbox poll discarded; local data was purged")
            return false
        }
        guard canWatch else {
            DiagnosticLog.verbose("Inbox poll paused; account or AI provider is unavailable")
            pauseWatching(resumeAfterManagedReauthentication: shouldResumeWatchingAfterManagedLicenseRecovery)
            return false
        }
        return true
    }

    func isCurrentWatcherPoll(
        localDataGeneration: UInt64,
        credentials: MailAccountCredentials
    ) -> Bool {
        isCurrentLocalDataGeneration(localDataGeneration)
            && watchStatus == .watching
            && mailCredentials == credentials
    }

    func handlePollFetchFailure(_ error: Error, localDataGeneration: UInt64) {
        guard isCurrentLocalDataGeneration(localDataGeneration) else { return }
        handlePollFetchFailure(error)
    }
}
