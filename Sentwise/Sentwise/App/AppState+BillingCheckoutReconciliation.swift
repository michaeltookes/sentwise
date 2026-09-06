import Foundation

private let billingCheckoutImmediateRefreshRetryDelays: [UInt64] = [
    750_000_000,
    1_500_000_000,
    3_000_000_000,
    6_000_000_000
]

private let billingReconciliationRetryDelays: [UInt64] = [
    60_000_000_000,
    300_000_000_000,
    900_000_000_000,
    1_800_000_000_000,
    3_600_000_000_000
]

/// Checkout and billing-portal refreshes split out from `AppState+Billing` so
/// Paddle webhook reconciliation can continue after the immediate retry budget.
extension AppState {
    func completeBillingCheckout(
        refreshRetryDelays: [UInt64] = billingCheckoutImmediateRefreshRetryDelays,
        reconciliationRetryDelays: [UInt64]? = nil
    ) async {
        cancelBillingReconciliation()
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
        scheduleBillingReconciliationIfNeeded(delays: reconciliationRetryDelays)
    }

    func scheduleBillingReconciliationIfNeeded(delays: [UInt64]? = nil) {
        let retryDelays = delays ?? billingReconciliationRetryDelays
        guard isManagedSignedIn, !isOnActivePaidPlan, !retryDelays.isEmpty else { return }
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
        guard isManagedSignedIn, !isOnActivePaidPlan else {
            billingReconciliationTask = nil
            return false
        }
        guard isOnline else { return true }
        await refreshManagedQuota(scheduleRetryOnFailure: false)
        if !isManagedSignedIn || isOnActivePaidPlan {
            billingReconciliationTask = nil
            return false
        }
        return true
    }

    private func finishBillingReconciliation() {
        billingReconciliationTask = nil
    }
}
