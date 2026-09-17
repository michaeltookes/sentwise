import SentwiseMail
import Foundation

/// Connecting mailboxes concurrently (item 99). Connecting a different account no
/// longer disconnects the current one: the previously focused account is kept
/// connected in the background (with its own watcher), and every saved account is
/// restored as a concurrently connected account at launch. Connecting beyond the
/// tier's account cap is blocked with an upgrade prompt.
extension AppState {

    /// A snapshot of the focused account taken before a focus change, so it can be
    /// re-homed as a background connected account.
    struct FocusedAccountSnapshot {
        let email: String
        let host: String
        let port: Int
        let password: String
        let watcherState: AccountWatcherRuntimeState
    }

    struct AccountWatcherRuntimeState {
        let watchStatus: WatchStatus
        let watchError: String?
        let resumeWatchingAfterManagedReauth: Bool
    }

    /// Loads the persisted settings and applies the tier gate for `newEmail`,
    /// returning the settings when the connect may proceed or nil (with the upgrade
    /// prompt surfaced) when the account cap blocks it (item 99).
    func connectionGatePassed(newEmail: String, messageSurface: TransientMessageSurface) -> Settings? {
        let previousSettings = persistence.loadSettings()
        guard passesConnectAccountGate(
            newEmail: newEmail,
            connectedFocusedEmail: previousSettings.mailEmail,
            messageSurface: messageSurface
        ) else { return nil }
        return previousSettings
    }

    /// Whether connecting `newEmail` is permitted by the tier's account cap, given
    /// the currently connected focused account's email (from persisted settings, so
    /// a mid-connect form value doesn't skew the count). An already-connected
    /// account may always reconnect. Surfaces the upgrade prompt when blocked.
    func passesConnectAccountGate(
        newEmail: String,
        connectedFocusedEmail: String,
        messageSurface: TransientMessageSurface
    ) -> Bool {
        let newKey = SavedMailAccount.normalizedEmail(newEmail)
        let focusedKey = SavedMailAccount.normalizedEmail(connectedFocusedEmail)
        let isReconnect = (!newKey.isEmpty && newKey == focusedKey)
            || backgroundConnectedAccount(email: newKey) != nil
        if isReconnect { return true }
        // The focused slot only counts when the focused account is actually
        // connected: `disconnectMail` clears `isAccountConnected` but leaves the
        // persisted `mailEmail`, so a disconnected mailbox must not keep occupying a
        // tier slot (item 99). `isAccountConnected` is not a form field, so it is
        // safe to combine with the persisted email used for identity.
        let focusedSlot = (focusedKey.isEmpty || !isAccountConnected) ? 0 : 1
        let currentCount = focusedSlot + backgroundConnectedAccounts.count
        guard currentCount < connectedAccountLimit else {
            setConnectionError(accountLimitUpgradeMessage, for: messageSurface)
            return false
        }
        return true
    }

    /// The previously focused (persisted) account as a background-handoff snapshot,
    /// with its app password read from the Keychain. Nil when nothing was connected.
    func previousFocusedSnapshot(from previousSettings: Settings) -> FocusedAccountSnapshot? {
        let email = previousSettings.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, isAccountConnected else { return nil }
        guard let password = storedMailPassword(forEmail: email), !password.isEmpty else { return nil }
        return FocusedAccountSnapshot(
            email: email,
            host: previousSettings.mailHost,
            port: previousSettings.mailPort,
            password: password,
            watcherState: focusedWatcherRuntimeState
        )
    }

    /// On focusing a different account, keep the previously focused account
    /// connected in the background and lift the newly focused account out of the
    /// background set, so exactly one runtime exists per connected mailbox.
    @discardableResult
    func adoptFocusChange(
        previousFocused: FocusedAccountSnapshot?,
        newFocusedEmail: String
    ) -> AccountWatcherRuntimeState? {
        let newKey = SavedMailAccount.normalizedEmail(newFocusedEmail)
        var promotedState: AccountWatcherRuntimeState?
        if let existing = backgroundConnectedAccount(email: newKey) {
            promotedState = watcherRuntimeState(for: existing)
            existing.watcher?.stop()
            backgroundConnectedAccounts.removeAll { $0.id == newKey }
        }

        guard let previousFocused,
              !previousFocused.password.isEmpty,
              SavedMailAccount.normalizedEmail(previousFocused.email) != newKey else {
            return promotedState
        }
        let previousKey = SavedMailAccount.normalizedEmail(previousFocused.email)
        backgroundConnectedAccounts.removeAll { $0.id == previousKey }
        let account = ConnectedMailAccount(
            email: previousFocused.email,
            host: previousFocused.host,
            port: previousFocused.port,
            appPassword: previousFocused.password
        )
        apply(previousFocused.watcherState, to: account)
        backgroundConnectedAccounts.append(account)
        if previousFocused.watcherState.watchStatus == .watching {
            ensureWatcher(for: account)
            account.watcher?.start()
        }
        return promotedState
    }

    /// Post-verify cleanup when the connected account changed or was reconnected:
    /// re-homes the previously focused account into the background (item 99), and
    /// restarts the focused watcher for the new account. Countdown timers are
    /// preserved because their drafts remain account-scoped when the source
    /// mailbox stays connected.
    func applyConnectionTransitionCleanup(
        previousFocused: FocusedAccountSnapshot?,
        newFocusedEmail: String
    ) {
        let outgoingState = previousFocused?.watcherState ?? focusedWatcherRuntimeState
        let promotedState = adoptFocusChange(
            previousFocused: previousFocused,
            newFocusedEmail: newFocusedEmail
        )
        if outgoingState.watchStatus == .watching {
            stopWatching(cancelCountdowns: false)
        } else {
            inboxWatcher.stop()
        }
        if let promotedState {
            applyFocusedWatcherRuntimeState(promotedState)
        } else if outgoingState.watchStatus == .watching {
            startWatchingIfReady()
        }
    }

    /// Restores every saved account (other than the focused one) as a concurrently
    /// connected background account at launch (item 99), up to the current tier's
    /// account cap. Watchers are started later by the normal `startWatchingIfReady`
    /// flow once the LLM is ready.
    func restoreBackgroundConnectedAccounts() {
        let focusedKey = SavedMailAccount.normalizedEmail(mailEmail)
        let availableBackgroundSlots = max(connectedAccountLimit - (isAccountConnected ? 1 : 0), 0)
        var restored: [ConnectedMailAccount] = []
        for saved in savedAccounts where saved.id != focusedKey {
            guard restored.count < availableBackgroundSlots else { break }
            guard let password = storedMailPassword(forEmail: saved.email), !password.isEmpty else { continue }
            restored.append(ConnectedMailAccount(
                email: saved.email, host: saved.host, port: saved.port, appPassword: password
            ))
        }
        backgroundConnectedAccounts = restored
    }

    /// Disconnects one background account: stops its watcher and removes its runtime.
    /// Optionally purges its local mail data first (item 96); a failed purge leaves
    /// the account connected and retryable.
    @discardableResult
    func disconnectBackgroundAccount(
        _ account: ConnectedMailAccount,
        purgeLocalData: Bool = false,
        messageSurface: TransientMessageSurface = .shared
    ) -> Bool {
        if purgeLocalData {
            stopWatching(account: account)
            do {
                try purgeLocalMailArtifacts(for: account.email, includeUnscopedArtifacts: false)
            } catch {
                setConnectionError("Couldn't erase local mail data. \(Self.message(for: error))", for: messageSurface)
                startWatchingIfReady(account: account)
                return false
            }
        }
        stopWatching(account: account)
        backgroundConnectedAccounts.removeAll { $0.id == account.id }
        return true
    }

    var focusedWatcherRuntimeState: AccountWatcherRuntimeState {
        AccountWatcherRuntimeState(
            watchStatus: watchStatus,
            watchError: watchError,
            resumeWatchingAfterManagedReauth: resumeWatchingAfterManagedReauth
        )
    }

    func watcherRuntimeState(for account: ConnectedMailAccount) -> AccountWatcherRuntimeState {
        AccountWatcherRuntimeState(
            watchStatus: account.watchStatus,
            watchError: account.watchError,
            resumeWatchingAfterManagedReauth: account.resumeWatchingAfterManagedReauth
        )
    }

    func apply(_ state: AccountWatcherRuntimeState, to account: ConnectedMailAccount) {
        account.watchStatus = state.watchStatus
        account.watchError = state.watchError
        account.resumeWatchingAfterManagedReauth = state.resumeWatchingAfterManagedReauth
    }

    func applyFocusedWatcherRuntimeState(_ state: AccountWatcherRuntimeState) {
        resumeWatchingAfterManagedReauth = state.resumeWatchingAfterManagedReauth
        watchError = state.watchError
        watchStatus = state.watchStatus
        switch state.watchStatus {
        case .watching:
            if canStartInboxWatcherImmediately {
                inboxWatcher.start()
            }
        case .idle, .paused:
            inboxWatcher.stop()
        }
    }
}
