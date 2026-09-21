import Foundation

/// User-configurable inbox-drafting policy (item 108). The watcher tiers'
/// default is *draft-on-click*: a reply-worthy message notifies the user and
/// enqueues an undrafted "awaiting request" entry, and no managed draft credit
/// is spent until the user clicks Draft. Automatic drafting — restoring the
/// pre-108 auto-generate-on-reply-worthy behavior — is an explicit opt-in with
/// two controls: a per-sender/domain auto-draft list (grown from item 18's
/// allowlist infrastructure) that auto-drafts chosen senders even when the
/// global toggle is off, and an optional monthly cap on how many of the
/// allotment auto-drafting may spend.
///
/// Persisted in `Settings` and mirrored onto `AppState` as a single published
/// sub-model (the `MailboxBrowserState`/`BulkCleanupState` pattern) so the
/// central `AppState` type stays within its file-length limit.
struct InboxDraftingSettings: Codable, Equatable {

    /// Whether reply-worthy inbox mail is automatically drafted (Pro/Unlimited/
    /// Trial opt-in). Default `false` — the watcher tiers' shipped default is
    /// draft-on-click, so a new install (and, via migration, every existing one)
    /// spends only on drafts the user asks for.
    var autoDraftEnabled: Bool

    /// Senders/domains to always auto-draft even when `autoDraftEnabled` is off
    /// (item 108). Reuses item 18's `SenderRule` model and matching; a separate
    /// list from the allow/blocklist so an existing "always draft" allowlist
    /// entry is never silently promoted to spend-without-asking.
    var autoDraftSenders: [SenderRule]

    /// Optional monthly cap on auto-generated drafts (`nil` = uncapped). When the
    /// cap is reached in the current allotment window, auto-drafting falls back to
    /// draft-on-click for the rest of the window. Counts only auto-generated
    /// drafts — manual on-demand and transcript follow-ups never count against it.
    var monthlyAutoDraftBudget: Int?

    init(
        autoDraftEnabled: Bool = false,
        autoDraftSenders: [SenderRule] = [],
        monthlyAutoDraftBudget: Int? = nil
    ) {
        self.autoDraftEnabled = autoDraftEnabled
        self.autoDraftSenders = autoDraftSenders
        self.monthlyAutoDraftBudget = monthlyAutoDraftBudget
    }

    /// A normalized copy: de-duplicated auto-draft rules and a non-negative cap
    /// (a zero or negative cap is treated as "no auto-drafting at all", i.e. `0`).
    func normalized() -> InboxDraftingSettings {
        var copy = self
        copy.autoDraftSenders = Settings.dedupedRules(autoDraftSenders)
        if let budget = monthlyAutoDraftBudget {
            copy.monthlyAutoDraftBudget = max(0, budget)
        }
        return copy
    }
}

/// Pure, IO-free tier policy for inbox watching (item 108), mirroring
/// `AccountConnectionLimit`. Client-side spend-intent policy keyed off
/// `subscription.plan` from `/v1/me` — the same accepted A-L5-style posture as
/// the account-count gate: a source-builder can bypass a client gate and open
/// core accepts this. It is **not** a security boundary; the managed proxy meters
/// and enforces spend server-side regardless of this gate.
enum InboxDraftingTierPolicy {

    /// Whether the inbox watcher (reply-worthiness gate + notifications) runs for
    /// `plan`. Starter has no inbox watcher at all — no background token burn.
    /// Pro/Unlimited/Trial watch. An unknown/offline/none plan follows the
    /// account-gate precedent and defaults to *allowed* (Pro-equivalent), so a
    /// legitimately-paid user who is briefly offline is never stranded without
    /// their watcher.
    static func allowsInboxWatching(for plan: ManagedSubscription.Plan?) -> Bool {
        switch plan {
        case .starter:
            return false
        case .pro, .unlimited, .trial:
            return true
        // `team` is reserved (not sold); treat as Pro-equivalent. Unknown/none/nil
        // fall back to the lenient default so an offline paid user keeps watching.
        case .team, .noPlan, .unknown, .none:
            return true
        }
    }

    /// Whether the opt-in automatic-drafting controls (global toggle, auto-draft
    /// list, budget cap) are offered for `plan`. Available exactly on the tiers
    /// that watch — Starter, having no watcher, never sees them.
    static func offersAutomaticDrafting(for plan: ManagedSubscription.Plan?) -> Bool {
        allowsInboxWatching(for: plan)
    }
}
