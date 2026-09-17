import SentwiseMail
import Foundation

/// Per-account watcher lifecycle for concurrently connected mailboxes (item 99).
/// The focused account keeps using the `AppState` single-account watcher; each
/// background connected account runs its own `InboxWatcher` polling with its own
/// credentials. `account == nil` throughout addresses the focused account so the
/// poll pipeline can be written once for both.
extension AppState {

    // MARK: - Per-account state accessors

    /// The watch status for a poll target: the focused account (nil) or a background one.
    func accountWatchStatus(_ account: ConnectedMailAccount?) -> WatchStatus {
        account?.watchStatus ?? watchStatus
    }

    func accountIsPolling(_ account: ConnectedMailAccount?) -> Bool {
        account?.isPollingInbox ?? isPollingInbox
    }

    func setAccountPolling(_ account: ConnectedMailAccount?, _ value: Bool) {
        if let account {
            account.isPollingInbox = value
        } else {
            isPollingInbox = value
        }
    }

    /// Sets the health error for a poll target. Background accounts aren't
    /// `@Published`, so nudge `objectWillChange` for the Settings list.
    func setWatchError(_ message: String?, account: ConnectedMailAccount?) {
        if let account {
            guard account.watchError != message else { return }
            objectWillChange.send()
            account.watchError = message
        } else {
            watchError = message
        }
    }

    // MARK: - Readiness

    /// Whether watching can run for a poll target. Mail must be connected for that
    /// account and a usable LLM provider must be ready (the LLM is app-global).
    func canWatch(account: ConnectedMailAccount?) -> Bool {
        guard let account else { return canWatch }
        return isConnectedAccount(account.credentials)
            && isLLMConnected
            && currentLLMProviderAllowsRequests
    }

    // MARK: - Lifecycle (background accounts delegate the focused case to AppState+Watcher)

    func startWatchingIfReady(account: ConnectedMailAccount?) {
        guard let account else { startWatchingIfReady(); return }
        guard canWatch(account: account), account.watchStatus != .watching else { return }
        startWatching(account: account)
    }

    func startWatching(account: ConnectedMailAccount?) {
        guard let account else { startWatching(); return }
        guard canWatch(account: account) else { return }
        account.resumeWatchingAfterManagedReauth = false
        recordWatcherBaselineStartIfNeeded(account: account.credentials.email, mailbox: .inbox)
        setAccountWatchStatus(account, .watching)
        setWatchError(nil, account: account)
        ensureWatcher(for: account)
        account.watcher?.start()
    }

    func pauseWatching(
        account: ConnectedMailAccount?,
        resumeAfterManagedReauthentication: Bool = false
    ) {
        guard let account else {
            pauseWatching(resumeAfterManagedReauthentication: resumeAfterManagedReauthentication)
            return
        }
        guard account.watchStatus == .watching else { return }
        account.resumeWatchingAfterManagedReauth = resumeAfterManagedReauthentication
        setAccountWatchStatus(account, .paused)
        account.watcher?.stop()
    }

    func stopWatching(account: ConnectedMailAccount?) {
        guard let account else { stopWatching(); return }
        guard account.watchStatus != .idle else { return }
        account.resumeWatchingAfterManagedReauth = false
        setAccountWatchStatus(account, .idle)
        account.watcher?.stop()
    }

    /// Starts every background account's watcher that is ready but idle (used at
    /// launch and when the LLM/license becomes available).
    func startAllBackgroundWatchersIfReady() {
        for account in backgroundConnectedAccounts {
            startWatchingIfReady(account: account)
        }
    }

    /// Stops every background account's watcher (used on erase/teardown).
    func stopAllBackgroundWatchers() {
        for account in backgroundConnectedAccounts {
            stopWatching(account: account)
        }
    }

    // MARK: - Helpers

    private func setAccountWatchStatus(_ account: ConnectedMailAccount, _ status: WatchStatus) {
        guard account.watchStatus != status else { return }
        objectWillChange.send()
        account.watchStatus = status
    }

    /// Lazily creates the account's own poll loop, wired to `pollInbox(account:)`.
    private func ensureWatcher(for account: ConnectedMailAccount) {
        guard account.watcher == nil else { return }
        account.watcher = InboxWatcher(
            interval: { [weak self] in TimeInterval(self?.pollIntervalSeconds ?? 300) },
            onTick: { [weak self, weak account] in
                guard let self, let account else { return }
                await self.pollInbox(account: account)
            }
        )
    }
}
