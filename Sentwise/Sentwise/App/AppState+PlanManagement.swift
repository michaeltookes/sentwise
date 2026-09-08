import Foundation

/// Immediate post-change `/v1/me` poll cadence (item 90). The Paddle
/// `subscription.updated` webhook write can lag the change-plan response by a
/// second or two, so we poll roughly every ~2s for ~15–20s, stopping early as
/// soon as the account's tier flips to the target. In Prowl hunt mode there is
/// no network and no poll.
private let planChangeReconcileRetryDelays: [UInt64] = [
    2_000_000_000,
    2_000_000_000,
    2_000_000_000,
    2_000_000_000,
    2_000_000_000,
    3_000_000_000,
    3_000_000_000
]

/// In-app plan management on `AppState` (backlog item 90): the account's current
/// purchasable tier, the upgrade/downgrade change-plan flow (a Paddle
/// subscription update with proration, reconciled against `/v1/me`), and the
/// billing-only confirmation/error copy. Cancellation and the on-demand
/// manage-billing fetch live in `AppState+BillingPortal`.
extension AppState {

    /// The account's current purchasable tier (Starter / Pro / Unlimited), or nil
    /// when the account is on a lifecycle plan that isn't one of the cards (trial /
    /// none / team / unknown). Prefers the freshest `/v1/me` subscription, falling
    /// back to the offline-grace snapshot.
    var currentSubscriptionPlanTier: PaddlePlan? {
        if let plan = managedAccountStatus?.subscription?.plan,
           let tier = PaddlePlan(subscriptionPlan: plan) {
            return tier
        }
        if let plan = effectiveSubscriptionSnapshot?.plan,
           let tier = PaddlePlan(subscriptionPlan: plan) {
            return tier
        }
        return nil
    }

    /// Whether the three-tier plan cards should be shown (item 90). Shown only when
    /// the account is on one of the purchasable tiers, so a trialing / lapsed /
    /// unknown account keeps the Subscribe entry point instead.
    var showsPlanManagement: Bool {
        isManagedSignedIn && currentSubscriptionPlanTier != nil
    }

    /// Switches the subscription to `tier` (item 90). No-op when not signed in,
    /// offline, already changing, not on a known tier, or already on `tier`. Calls
    /// `POST /v1/paddle/change-plan` (a prorated Paddle subscription update), then
    /// polls `/v1/me` until the account's tier flips, and finally surfaces a
    /// billing-only confirmation. Endpoint errors map to friendly, billing-only
    /// copy in `planChangeMessage`.
    func changePlan(
        to tier: PaddlePlan,
        reconcileRetryDelays: [UInt64] = planChangeReconcileRetryDelays
    ) async {
        guard isManagedSignedIn, isOnline, !isChangingPlan,
              let current = currentSubscriptionPlanTier, current != tier else {
            return
        }
        planChangeMessage = nil
        planChangeFailed = false
        isChangingPlan = true
        changingPlanTier = tier
        defer {
            isChangingPlan = false
            changingPlanTier = nil
        }

        let priceID = PaddleConfig.active.priceID(for: tier)
        do {
            _ = try await llm.changeManagedPlan(priceID: priceID)
        } catch {
            await reconcileManagedAccountState(after: error, provider: .managed)
            planChangeFailed = true
            planChangeMessage = Self.changePlanErrorMessage(for: error)
            return
        }

        await reconcilePlanChange(to: tier, retryDelays: reconcileRetryDelays)
        planChangeFailed = false
        planChangeMessage = Self.changePlanConfirmation(for: tier)
    }

    /// Polls `/v1/me` after a successful change-plan call until the account's tier
    /// becomes `tier` (item 90), so the pane reflects the new plan. Stops early
    /// once the tier flips. In Prowl hunt mode `refreshManagedQuota` is a
    /// deterministic no-op, so this neither polls the network nor blocks.
    func reconcilePlanChange(to tier: PaddlePlan, retryDelays: [UInt64]) async {
        await refreshManagedQuota()
        if currentSubscriptionPlanTier == tier { return }
        // Hunt mode never flips the deterministic stub tier — don't spin the poll.
        guard !ProwlHuntRuntime.current.isEnabled else { return }

        for delay in retryDelays {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard isManagedSignedIn, isOnline else { return }
            await refreshManagedQuota()
            if currentSubscriptionPlanTier == tier { return }
        }
    }

    /// A short confirm prompt for switching to `tier` (item 90). Billing-only —
    /// no privacy/retention claims. Names whether it reads as an upgrade or a
    /// downgrade relative to the current tier when that is known.
    func changePlanPrompt(for tier: PaddlePlan) -> String {
        let verb = currentSubscriptionPlanTier.map { tier.isUpgrade(from: $0) ? "Upgrade to" : "Switch to" }
            ?? "Switch to"
        return "\(verb) \(tier.displayName)? Your plan changes now, prorated."
    }

    /// Billing-only confirmation copy after a successful plan change (item 90).
    static func changePlanConfirmation(for tier: PaddlePlan) -> String {
        "You're on \(tier.displayName). The change is prorated to your billing date."
    }

    /// Billing-only copy for a failed plan change (item 90). Surfaces the Worker's
    /// own message when present (it already maps same-plan / no-subscription /
    /// Paddle-unavailable to user-safe text); otherwise a neutral retry line.
    static func changePlanErrorMessage(for error: Error) -> String {
        switch error {
        case LLMError.managedChangePlanFailed(let message):
            return message
        case LLMError.managedNotSignedIn:
            return "Sign in to Sentwise AI to change your plan."
        case LLMError.transport:
            return "We couldn't reach billing. Check your connection and try again."
        default:
            return "We couldn't switch your plan just now. Please try again."
        }
    }
}
