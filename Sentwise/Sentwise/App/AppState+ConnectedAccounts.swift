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
    /// `mailCredentials == credentials` guard to the multi-account world — keyed on
    /// credential completeness (not the verified `isAccountConnected` flag) so the
    /// manual draft/dispatch paths behave exactly as before for the focused account.
    func isConnectedAccount(_ credentials: MailAccountCredentials) -> Bool {
        if mailCredentials.isComplete, mailCredentials == credentials { return true }
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
        // The focused account is usable for dispatch whenever its credentials are
        // complete (mirrors the pre-item-99 dispatch path), regardless of whether
        // the verified `isAccountConnected` flag has been set.
        if SavedMailAccount.normalizedEmail(mailEmail) == key, mailCredentials.isComplete {
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

    /// Whether the account identified by `credentials` (focused or background) is
    /// currently watching. Generalizes the old `watchStatus == .watching` check to
    /// the account whose poll is in flight (item 99).
    func isAccountWatching(_ credentials: MailAccountCredentials) -> Bool {
        if mailCredentials == credentials {
            return watchStatus == .watching
        }
        return backgroundConnectedAccounts.first { $0.credentials == credentials }?.watchStatus == .watching
    }

    /// Resolves the credentials to dispatch `draft` from — the account the message
    /// arrived in (item 99), so a reply is sent/saved from that mailbox even when a
    /// different account is focused. Throws `.missingCredentials` when no mailbox is
    /// connected, `.accountMismatch` when the draft's source account is not among
    /// the connected accounts.
    func dispatchCredentials(forDraft draft: Draft) throws -> MailAccountCredentials {
        if let sourceEmail = draft.sourceAccountEmail,
           let credentials = connectedCredentials(forAccountEmail: sourceEmail),
           credentials.isComplete {
            return credentials
        }
        // The draft's source account isn't available. Distinguish "no mailbox
        // connected at all" (missing) from "a different account is connected"
        // (mismatch), preserving the pre-item-99 error copy.
        let anyAccountAvailable = mailCredentials.isComplete || !backgroundConnectedAccounts.isEmpty
        throw anyAccountAvailable ? DraftDispatchError.accountMismatch : DraftDispatchError.missingCredentials
    }
}
