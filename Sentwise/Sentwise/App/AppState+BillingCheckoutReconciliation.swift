import Foundation

private let billingCheckoutImmediateRefreshRetryDelays: [UInt64] = [
    750_000_000,
    1_500_000_000,
    3_000_000_000,
    6_000_000_000
]

private let billingCheckoutReconciliationRetryDelays: [UInt64] = [
    60_000_000_000,
    300_000_000_000,
    900_000_000_000,
    1_800_000_000_000,
    3_600_000_000_000
]

/// Checkout completion refreshes split out from `AppState+Billing` so the
/// long-lived Paddle webhook reconciliation can continue after the immediate
/// overlay-completion retry budget is exhausted.
extension AppState {
    func completeBillingCheckout(
        refreshRetryDelays: [UInt64] = billingCheckoutImmediateRefreshRetryDelays,
        reconciliationRetryDelays: [UInt64]? = nil
    ) async {
        cancelBillingCheckoutReconciliation()
        billingCheckout = nil
        await refreshManagedQuota()
        guard isManagedSignedIn, !isOnActivePaidPlan else { return }

        for delay in refreshRetryDelays {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard isManagedSignedIn else { return }
            await refreshManagedQuota()
            if isOnActivePaidPlan { return }
        }
        scheduleBillingCheckoutReconciliationIfNeeded(delays: reconciliationRetryDelays)
    }

    func scheduleBillingCheckoutReconciliationIfNeeded(delays: [UInt64]? = nil) {
        let retryDelays = delays ?? billingCheckoutReconciliationRetryDelays
        guard isManagedSignedIn, !isOnActivePaidPlan, !retryDelays.isEmpty else { return }
        cancelBillingCheckoutReconciliation()
        billingCheckoutReconciliationTask = Task { [weak self] in
            for delay in retryDelays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self else { return }
                let shouldContinue = await self.refreshManagedQuotaForBillingCheckoutReconciliation()
                if !shouldContinue { return }
            }
            self?.finishBillingCheckoutReconciliation()
        }
    }

    func cancelBillingCheckoutReconciliation() {
        billingCheckoutReconciliationTask?.cancel()
        billingCheckoutReconciliationTask = nil
    }

    private func refreshManagedQuotaForBillingCheckoutReconciliation() async -> Bool {
        guard isManagedSignedIn, !isOnActivePaidPlan else {
            billingCheckoutReconciliationTask = nil
            return false
        }
        guard isOnline else { return true }
        await refreshManagedQuota(scheduleRetryOnFailure: false)
        if !isManagedSignedIn || isOnActivePaidPlan {
            billingCheckoutReconciliationTask = nil
            return false
        }
        return true
    }

    private func finishBillingCheckoutReconciliation() {
        billingCheckoutReconciliationTask = nil
    }
}
