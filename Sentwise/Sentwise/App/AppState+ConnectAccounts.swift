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
        let wasWatching: Bool
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
        let currentCount = (focusedKey.isEmpty ? 0 : 1) + backgroundConnectedAccounts.count
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
            wasWatching: watchStatus == .watching
        )
    }

    /// On focusing a different account, keep the previously focused account
    /// connected in the background and lift the newly focused account out of the
    /// background set, so exactly one runtime exists per connected mailbox.
    func adoptFocusChange(previousFocused: FocusedAccountSnapshot?, newFocusedEmail: String) {
        let newKey = SavedMailAccount.normalizedEmail(newFocusedEmail)
        if let existing = backgroundConnectedAccount(email: newKey) {
            stopWatching(account: existing)
            backgroundConnectedAccounts.removeAll { $0.id == newKey }
        }

        guard let previousFocused,
              !previousFocused.password.isEmpty,
              SavedMailAccount.normalizedEmail(previousFocused.email) != newKey else {
            return
        }
        let previousKey = SavedMailAccount.normalizedEmail(previousFocused.email)
        backgroundConnectedAccounts.removeAll { $0.id == previousKey }
        let account = ConnectedMailAccount(
            email: previousFocused.email,
            host: previousFocused.host,
            port: previousFocused.port,
            appPassword: previousFocused.password
        )
        backgroundConnectedAccounts.append(account)
        if previousFocused.wasWatching {
            startWatchingIfReady(account: account)
        }
    }

    /// Post-verify cleanup when the connected account changed or was reconnected:
    /// invalidates in-flight countdowns/offline queue, re-homes the previously
    /// focused account into the background (item 99), and restarts the focused
    /// watcher for the new account.
    func applyConnectionTransitionCleanup(
        accountIdentityChanged: Bool,
        wasWatching: Bool,
        previousFocused: FocusedAccountSnapshot?,
        newFocusedEmail: String
    ) {
        cancelAllSendCountdowns()
        if accountIdentityChanged {
            adoptFocusChange(previousFocused: previousFocused, newFocusedEmail: newFocusedEmail)
        }
        if wasWatching {
            stopWatching()
            startWatchingIfReady()
        }
    }

    /// Restores every saved account (other than the focused one) as a concurrently
    /// connected background account at launch (item 99). Watchers are started later
    /// by the normal `startWatchingIfReady` flow once the LLM is ready.
    func restoreBackgroundConnectedAccounts() {
        let focusedKey = SavedMailAccount.normalizedEmail(mailEmail)
        var restored: [ConnectedMailAccount] = []
        for saved in savedAccounts where saved.id != focusedKey {
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
}
