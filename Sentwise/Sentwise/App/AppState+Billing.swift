import AppKit
import Foundation

/// A request to present the Paddle overlay-checkout sheet (backlog item 56c).
/// `plan == nil` opens the sheet on the plan picker; a non-nil plan jumps
/// straight to that tier's checkout. `Identifiable` so it drives `.sheet(item:)`.
struct BillingCheckoutRequest: Identifiable, Equatable {
    let id = UUID()
    /// The tier to purchase, or nil to let the user pick first.
    let plan: PaddlePlan?

    init(plan: PaddlePlan? = nil) {
        self.plan = plan
    }
}

/// Checkout + licensing actions on `AppState` (backlog item 56c, app half): the
/// Paddle checkout entry points, "Manage billing" wiring, the Clerk-user-id
/// threading for checkout attribution, and the offline license-grace evaluation.
/// Kept in its own file so `AppState` stays within length limits, mirroring
/// `AppState+LLM` / `AppState+ManagedAccount`.
extension AppState {

    // MARK: - Clerk identity for checkout

    /// The bare Clerk user id for the signed-in account (e.g. `user_123`), used as
    /// `customData.clerkUserId` so the Paddle webhook can attribute the purchase.
    /// Prefers the freshest `/v1/me` value, falling back to the persisted stable
    /// account id (`clerk-user:<id>`); nil when unknown.
    var managedClerkUserID: String? {
        if let userID = managedAccountStatus?.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            return userID
        }
        let stored = managedAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "clerk-user:"
        guard stored.hasPrefix(prefix) else { return nil }
        let id = String(stored.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    // MARK: - Checkout entry points

    /// Opens the checkout sheet (item 56c). Pass a `plan` to jump straight to that
    /// tier, or nil to show the plan picker. No-op when not signed in — the
    /// webhook needs a Clerk account to attribute the purchase, so the pane surfaces
    /// the sign-in controls instead.
    func presentBillingCheckout(plan: PaddlePlan? = nil) {
        guard isManagedSignedIn else { return }
        billingCheckout = BillingCheckoutRequest(plan: plan)
    }

    /// Builds the checkout model for a chosen tier, threading in the signed-in
    /// account's Clerk user id and email.
    func makeCheckoutModel(for plan: PaddlePlan) -> PaddleCheckoutModel {
        PaddleCheckoutModel(
            config: .active,
            plan: plan,
            clerkUserID: managedClerkUserID,
            email: managedAccountDisplayEmail
        )
    }

    /// Called by the checkout sheet after a `checkout.completed` event so the
    /// webhook-written subscription is reflected. Dismisses the sheet and refreshes
    /// `/v1/me`.
    func completeBillingCheckout() async {
        billingCheckout = nil
        await refreshManagedQuota()
    }

    // MARK: - Manage billing

    /// The merchant-of-record billing-portal URL when the Worker provides one.
    /// Prefers the live status; falls back to the cached snapshot so the button
    /// still works from a last-known value while offline (item 56c).
    var manageBillingURL: URL? {
        let raw = managedAccountStatus?.subscription?.manageBillingURL
            ?? effectiveSubscriptionSnapshot?.manageBillingURL
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            return nil
        }
        return url
    }

    /// Whether "Manage billing" should be enabled — a portal URL is known.
    var canManageBilling: Bool { manageBillingURL != nil }

    /// Opens the Paddle customer portal in the default browser (item 56c).
    func openManageBilling() {
        guard let url = manageBillingURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Subscribe affordance

    /// Whether the account is on an active, purchased paid plan. Drives whether the
    /// pane shows "Subscribe/Upgrade" (not on a paid plan) vs. "Manage billing"
    /// (on a paid plan).
    var isOnActivePaidPlan: Bool {
        guard let sub = managedAccountStatus?.subscription else { return false }
        let paid: Set<ManagedSubscription.Plan> = [.starter, .pro, .unlimited, .team]
        return sub.status == .active && paid.contains(sub.plan)
    }

    /// Whether to offer the subscribe/upgrade CTA. Offered whenever the account is
    /// not on an active paid plan (trialing, lapsed, past_due, canceled, none, or
    /// unknown) — i.e. any state a purchase would move forward.
    var shouldOfferSubscribe: Bool {
        isManagedSignedIn && !isOnActivePaidPlan
    }

    // MARK: - Offline license grace

    /// The last-known subscription snapshot for the current account: the freshly
    /// captured one when present, else the durable per-account cache. Backs the
    /// offline-grace evaluation so a signed-in account keeps its entitlement across
    /// a launch or an outage (item 56c).
    var effectiveSubscriptionSnapshot: SubscriptionSnapshot? {
        if let cachedSubscriptionSnapshot { return cachedSubscriptionSnapshot }
        guard isManagedSignedIn else { return nil }
        let snapshot = subscriptionCacheStore.snapshot(accountKey: currentManagedUsageAccountKey)
        return snapshot
    }

    /// The evaluated entitlement for managed drafting (item 56c). Uses the live
    /// `/v1/me` status when online; when offline (or the status is unknown) it
    /// falls back to the cached snapshot within a grace window, so the app/UI never
    /// hard-fails offline. Recomputed by SwiftUI whenever the status changes.
    var managedLicense: SubscriptionLicense {
        let liveStatus = isOnline ? managedAccountStatus?.subscription?.status : nil
        return SubscriptionLicenseEvaluator.evaluate(
            liveStatus: liveStatus,
            cached: effectiveSubscriptionSnapshot
        )
    }

    /// Persists the last-known subscription from a successful `/v1/me` so offline
    /// grace has something to fall back on. No-op when the status carries no
    /// subscription block (older Worker).
    func recordSubscriptionSnapshot(from status: ManagedAccountStatus) {
        guard let snapshot = SubscriptionSnapshot(subscription: status.subscription) else { return }
        cachedSubscriptionSnapshot = snapshot
        subscriptionCacheStore.save(snapshot, accountKey: currentManagedUsageAccountKey)
    }

    /// Clears the in-memory offline-grace snapshot (called on sign-out alongside
    /// the quota cache). The durable per-account store is cleared separately so a
    /// re-sign-in on the same account can still read its last-known entitlement.
    func clearCachedSubscriptionSnapshot() {
        cachedSubscriptionSnapshot = nil
    }
}
