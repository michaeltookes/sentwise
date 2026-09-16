import SentwiseMail
import Foundation

/// Multi-account registry and tier-gated connection limit on `AppState` (item 99).
/// The focused account lives in the single-account fields; `backgroundConnectedAccounts`
/// holds the additional mailboxes connected concurrently. Query helpers here let
/// the draft/dispatch pipeline reason about *all* connected accounts, and the
/// connection UI gate against the subscription tier's account cap.
extension AppState {

    // MARK: - Tier gate (docs/tier-matrix.md)

    /// The subscription plan the account-count gate keys off: the live `/v1/me`
    /// value when known, else the cached snapshot (so an offline launch still gates
    /// correctly), else nil.
    var currentSubscriptionPlan: ManagedSubscription.Plan? {
        managedAccountStatus?.subscription?.plan ?? cachedSubscriptionSnapshot?.plan
    }

    /// The maximum number of concurrently connected mailboxes for the current plan
    /// (Starter 1, Pro 2, Unlimited 5, Trial 2). Client-side, per `docs/tier-matrix.md`.
    var connectedAccountLimit: Int {
        AccountConnectionLimit.maxConnectedAccounts(for: currentSubscriptionPlan)
    }

    /// How many mailboxes are connected right now: the focused account (if
    /// connected) plus every background connected account.
    var connectedAccountCount: Int {
        (isAccountConnected ? 1 : 0) + backgroundConnectedAccounts.count
    }

    /// Whether another mailbox may be connected without exceeding the tier cap.
    var canConnectAnotherAccount: Bool {
        connectedAccountCount < connectedAccountLimit
    }

    /// Whether connecting `email` is allowed: an already-connected account may
    /// always reconnect (it doesn't grow the count); a new one is gated by the cap.
    func canConnectAccount(email: String) -> Bool {
        if isConnectedAccount(email: email) { return true }
        return canConnectAnotherAccount
    }

    /// The upgrade-prompt message shown when a connect is blocked by the tier cap.
    var accountLimitUpgradeMessage: String {
        let limit = connectedAccountLimit
        let mailboxes = limit == 1 ? "mailbox" : "mailboxes"
        return "Your plan connects up to \(limit) \(mailboxes). Upgrade to connect another."
    }

    // MARK: - Registry queries

    /// Normalized emails of every connected mailbox (focused + background).
    var allConnectedAccountEmails: [String] {
        var emails: [String] = []
        if isAccountConnected {
            emails.append(SavedMailAccount.normalizedEmail(mailEmail))
        }
        emails.append(contentsOf: backgroundConnectedAccounts.map(\.id))
        return emails
    }

    /// Whether `email` is currently connected (as the focused or a background account).
    func isConnectedAccount(email: String) -> Bool {
        let key = SavedMailAccount.normalizedEmail(email)
        guard !key.isEmpty else { return false }
        return allConnectedAccountEmails.contains(key)
    }

    /// Whether `credentials` belongs to a currently connected account (focused or
    /// background) with matching connection details. Generalizes the old
    /// `mailCredentials == credentials` guard to the multi-account world.
    func isConnectedAccount(_ credentials: MailAccountCredentials) -> Bool {
        if isAccountConnected, mailCredentials == credentials { return true }
        return backgroundConnectedAccounts.contains { $0.credentials == credentials }
    }

    /// The background runtime for `email`, if connected.
    func backgroundConnectedAccount(email: String) -> ConnectedMailAccount? {
        let key = SavedMailAccount.normalizedEmail(email)
        return backgroundConnectedAccounts.first { $0.id == key }
    }

    /// Resolves the connection credentials for `email` across all connected
    /// accounts: the focused account's live inputs, or a background runtime's. Used
    /// so a draft is dispatched from the mailbox it arrived in (item 99).
    func connectedCredentials(forAccountEmail email: String) -> MailAccountCredentials? {
        let key = SavedMailAccount.normalizedEmail(email)
        guard !key.isEmpty else { return nil }
        if isAccountConnected, SavedMailAccount.normalizedEmail(mailEmail) == key {
            return mailCredentials
        }
        return backgroundConnectedAccount(email: key)?.credentials
    }

    /// This account's independent watch status (focused or background), for the
    /// per-account health shown in Settings.
    func watchStatus(forAccountEmail email: String) -> AppState.WatchStatus {
        let key = SavedMailAccount.normalizedEmail(email)
        if isAccountConnected, SavedMailAccount.normalizedEmail(mailEmail) == key {
            return watchStatus
        }
        return backgroundConnectedAccount(email: key)?.watchStatus ?? .idle
    }
}
