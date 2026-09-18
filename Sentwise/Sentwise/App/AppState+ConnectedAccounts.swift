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
        managedAccountStatus?.subscription?.plan ?? effectiveSubscriptionSnapshot?.plan
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

    /// Whether Review Drafts and Activity should badge each item with the mailbox
    /// it belongs to (item 99). Only meaningful once more than one mailbox can
    /// appear in the review surface, including retained drafts/skips for accounts
    /// the user disconnected without purging local data.
    var showsAccountAttribution: Bool {
        attributionMailboxes.count > 1
    }

    /// The short mailbox label for account attribution — the account's email.
    /// Returns nil for an untagged (legacy) record.
    func accountAttributionLabel(forEmail email: String?) -> String? {
        guard let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return email
    }

    /// The compact source-mailbox badge for a collapsed Review Drafts row (item
    /// 102): the account label when attribution is shown and the draft is tagged,
    /// else nil so single-account users and legacy (untagged) drafts show none.
    func draftRowAccountBadge(for draft: Draft) -> String? {
        guard showsAccountAttribution else { return nil }
        return accountAttributionLabel(forEmail: draft.sourceAccountEmail)
    }

    /// Every mailbox that can own a Review Drafts item, for the account picker
    /// (item 102): the union of saved accounts, connected accounts, the focused
    /// mailbox, and retained draft/skip source accounts — normalized,
    /// de-duplicated, and sorted for a stable menu order. Legacy untagged items
    /// are reached through the picker's "All Mailboxes" entry, so they need no
    /// dedicated row here.
    var attributionMailboxes: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        func add(_ email: String) {
            let normalized = SavedMailAccount.normalizedEmail(email)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            ordered.append(normalized)
        }
        savedAccounts.forEach { add($0.email) }
        allConnectedAccountEmails.forEach(add)
        if isAccountConnected { add(mailEmail) }
        pendingDrafts.forEach { add($0.sourceAccountEmail ?? "") }
        skippedMessages.forEach { add($0.account) }
        reviewSkippedMessages.forEach { add($0.account) }
        return ordered.sorted()
    }

    // MARK: - Mailbox browser account selection (item 103)

    /// The connected mailboxes the Browse window can point at (item 103): focused
    /// first, then background accounts. Only *connected* accounts appear — the
    /// browser needs live credentials, so a saved-but-disconnected account is not
    /// browsable.
    var browsableAccountEmails: [String] {
        allConnectedAccountEmails
    }

    /// Whether the Browse window shows its account picker (item 103): only with
    /// more than one connected mailbox, so single-account users — and Prowl hunt
    /// mode, which seeds one fixture account — never see it.
    var showsBrowserAccountPicker: Bool {
        browsableAccountEmails.count > 1
    }

    /// The normalized email of the mailbox the Browse window is currently showing
    /// (item 103): the explicitly picked account when it is still connected, else
    /// the first connected mailbox. `disconnectMail` can leave the focused email
    /// populated but offline, so falling back to `mailEmail` alone would strand
    /// the browser on incomplete credentials while background mailboxes remain.
    var effectiveBrowserAccountEmail: String {
        if let email = browser.accountEmail, isConnectedAccount(email: email) {
            return SavedMailAccount.normalizedEmail(email)
        }
        return browsableAccountEmails.first ?? SavedMailAccount.normalizedEmail(mailEmail)
    }

    /// The credentials the mailbox browser and bulk cleanup operate through (item
    /// 103): the picked account's when one is selected and still connected, else
    /// the focused account's live inputs. This is the single seam that points
    /// browse/search/pagination/cleanup at the chosen mailbox — no second
    /// credential store.
    var browserCredentials: MailAccountCredentials {
        let email = effectiveBrowserAccountEmail
        if !email.isEmpty,
           let credentials = connectedCredentials(forAccountEmail: email) {
            return credentials
        }
        return mailCredentials
    }

    /// Switches the Browse window to another connected mailbox (item 103): resets
    /// the browser and cleanup state and generations so no results mix across
    /// accounts and no stale page appends, then points the (now-clean) browser at
    /// the picked account. The global focused account is untouched. A no-op if the
    /// target is not a connected account.
    func selectBrowserAccount(_ email: String) {
        let normalized = SavedMailAccount.normalizedEmail(email)
        guard isConnectedAccount(email: normalized) else { return }
        guard normalized != effectiveBrowserAccountEmail else { return }
        resetBrowserScopedPreviewsForAccountChange()
        // Re-apply after the reset, which wipes the whole browser state.
        browser.accountEmail = normalized
    }

    /// Resets the Browse window if it is currently scoped to `email`. Used when a
    /// background account disconnects so stale result UIDs and checked rows never
    /// fall through to the focused account.
    func resetBrowserIfShowingAccount(_ email: String) {
        let normalized = SavedMailAccount.normalizedEmail(email)
        let explicitAccount = SavedMailAccount.normalizedEmail(browser.accountEmail ?? "")
        let effectiveAccount = SavedMailAccount.normalizedEmail(effectiveBrowserAccountEmail)
        guard !normalized.isEmpty,
              explicitAccount == normalized || effectiveAccount == normalized else {
            return
        }
        resetBrowserScopedPreviewsForAccountChange()
    }

    /// Clears browser-scoped rows/actions. Explicit Browse body/draft requests
    /// already guard completions against `browserCredentials`, so switching the
    /// Browse mailbox does not need to touch Settings preview/draft state.
    func resetBrowserScopedPreviewsForAccountChange() {
        resetMailboxBrowserForAccountChange()
        resetBulkCleanupForAccountChange()
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

    /// This account's last watcher health error (focused or background), if any.
    func watchError(forAccountEmail email: String) -> String? {
        let key = SavedMailAccount.normalizedEmail(email)
        if isAccountConnected, SavedMailAccount.normalizedEmail(mailEmail) == key {
            return watchError
        }
        return backgroundConnectedAccount(email: key)?.watchError
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
