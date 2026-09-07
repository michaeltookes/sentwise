import Foundation

/// Immediate post-purchase `/v1/me` poll cadence (item 56c). The Paddle webhook
/// write can lag the overlay's `checkout.completed` by a second or two, so we
/// poll roughly every ~2s for ~15–20s, stopping early as soon as the plan flips
/// to a paid tier. In Prowl hunt mode there is no network and no poll.
private let billingCheckoutImmediateRefreshRetryDelays: [UInt64] = [
    2_000_000_000,
    2_000_000_000,
    2_000_000_000,
    2_000_000_000,
    2_000_000_000,
    3_000_000_000,
    3_000_000_000
]

private let billingReconciliationRetryDelays: [UInt64] = [
    60_000_000_000,
    300_000_000_000,
    900_000_000_000,
    1_800_000_000_000,
    3_600_000_000_000
]

struct BillingReconciliationQuotaSnapshot: Equatable {
    let unit: String
    let limit: Int
    let tokenLimit: Int
    let enforcement: ManagedQuota.Enforcement
    let extraPurchased: Int
}

struct BillingSubscriptionSnapshot: Equatable {
    let plan: ManagedSubscription.Plan
    let status: ManagedSubscription.Status
    let renewsAt: Date?
}

struct BillingReconciliationSnapshot: Equatable {
    let subscription: BillingSubscriptionSnapshot?
    let quota: BillingReconciliationQuotaSnapshot?
}

/// Checkout and billing-portal refreshes split out from `AppState+Billing` so
/// Paddle webhook reconciliation can continue after the immediate retry budget.
extension AppState {
    /// Completes a checkout and dismisses the sheet, then reconciles the account.
    /// Retained for callers/tests that want the legacy "dismiss + refresh" in one
    /// call. The checkout sheet itself uses `reconcileSubscriptionAfterCheckout`
    /// so it can keep the sheet open to show a success confirmation (item 56c).
    func completeBillingCheckout(
        refreshRetryDelays: [UInt64] = billingCheckoutImmediateRefreshRetryDelays,
        reconciliationRetryDelays: [UInt64]? = nil
    ) async {
        billingCheckout = nil
        await reconcileSubscriptionAfterCheckout(
            refreshRetryDelays: refreshRetryDelays,
            reconciliationRetryDelays: reconciliationRetryDelays
        )
    }

    /// Polls `/v1/me` after a completed purchase until the paid tier is visible
    /// (item 56c), WITHOUT dismissing the checkout sheet — so the sheet can show a
    /// success confirmation while (and after) the account flips. Stops early once
    /// the plan becomes a paid tier; if the immediate budget is exhausted it hands
    /// off to the longer background reconciliation. In Prowl hunt mode
    /// `refreshManagedQuota` is a deterministic no-op, so this neither polls the
    /// network nor blocks.
    func reconcileSubscriptionAfterCheckout(
        refreshRetryDelays: [UInt64] = billingCheckoutImmediateRefreshRetryDelays,
        reconciliationRetryDelays: [UInt64]? = nil
    ) async {
        cancelBillingReconciliation()
        billingReconciliationBaseline = nil
        await refreshManagedQuota()
        guard isManagedSignedIn, !billingReconciliationIsComplete else { return }

        for delay in refreshRetryDelays {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard isManagedSignedIn else { return }
            await refreshManagedQuota()
            if billingReconciliationIsComplete { return }
        }
        scheduleBillingReconciliationIfNeeded(delays: reconciliationRetryDelays)
    }

    func scheduleBillingReconciliationIfNeeded(delays: [UInt64]? = nil) {
        let retryDelays = delays ?? billingReconciliationRetryDelays
        guard isManagedSignedIn, !retryDelays.isEmpty else {
            finishBillingReconciliation()
            return
        }
        guard !billingReconciliationIsComplete else {
            finishBillingReconciliation()
            return
        }
        cancelBillingReconciliation()
        billingReconciliationTask = Task { [weak self] in
            for delay in retryDelays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self else { return }
                let shouldContinue = await self.refreshManagedQuotaForBillingReconciliation()
                if !shouldContinue { return }
            }
            self?.finishBillingReconciliation()
        }
    }

    func cancelBillingReconciliation() {
        billingReconciliationTask?.cancel()
        billingReconciliationTask = nil
    }

    private func refreshManagedQuotaForBillingReconciliation() async -> Bool {
        guard isManagedSignedIn, !billingReconciliationIsComplete else {
            finishBillingReconciliation()
            return false
        }
        guard isOnline else { return true }
        await refreshManagedQuota(scheduleRetryOnFailure: false)
        if !isManagedSignedIn || billingReconciliationIsComplete {
            finishBillingReconciliation()
            return false
        }
        return true
    }

    private func finishBillingReconciliation() {
        billingReconciliationTask = nil
        billingReconciliationBaseline = nil
    }

    private var billingReconciliationIsComplete: Bool {
        guard let billingReconciliationBaseline else { return isOnActivePaidPlan }
        return currentBillingReconciliationSnapshot != billingReconciliationBaseline
    }

    var currentBillingReconciliationSnapshot: BillingReconciliationSnapshot {
        let subscription = managedAccountStatus?.subscription.map {
            BillingSubscriptionSnapshot(
                plan: $0.plan,
                status: $0.status,
                renewsAt: $0.renewsAt
            )
        }
            ?? effectiveSubscriptionSnapshot.map {
                BillingSubscriptionSnapshot(
                    plan: $0.plan,
                    status: $0.status,
                    renewsAt: $0.renewsAt
                )
            }
        return BillingReconciliationSnapshot(
            subscription: subscription,
            quota: managedQuota.map {
                BillingReconciliationQuotaSnapshot(
                    unit: $0.unit,
                    limit: $0.limit,
                    tokenLimit: $0.tokenLimit,
                    enforcement: $0.enforcement,
                    extraPurchased: $0.extraPurchased
                )
            }
        )
    }
}
