import Foundation

extension AppState {

    func finishPlanChangeReconciliation(generation: UInt64, preservePendingConfirmation: Bool = false) {
        guard planChangeReconciliationGeneration == generation else { return }
        planChangeReconciliationTask?.cancel()
        planChangeReconciliationTask = nil
        if pendingPlanChangeReconciliation?.generation == generation && !preservePendingConfirmation {
            pendingPlanChangeReconciliation = nil
        }
    }

    func shouldDeferStatusRefreshForPendingPlanChange(_ status: ManagedAccountStatus) -> Bool {
        guard planChangeReconciliationTask != nil,
              let pending = pendingPlanChangeReconciliation,
              pending.generation == planChangeReconciliationGeneration,
              managedAccountMatches(pending.accountKey) else {
            return false
        }
        return !statusConfirmsPendingPlanChange(status, pending: pending)
    }

    func finishPendingPlanChangeReconciliationIfConfirmed(by status: ManagedAccountStatus) {
        guard let pending = pendingPlanChangeReconciliation,
              pending.generation == planChangeReconciliationGeneration,
              managedAccountMatches(pending.accountKey),
              statusConfirmsPendingPlanChange(status, pending: pending) else {
            return
        }
        if status.quota == nil && !managedAccountStatusIsFresh {
            publishPendingPlanChangeConfirmationIfCurrent(pending)
            return
        }
        finishPlanChangeReconciliation(generation: pending.generation)
        publishPendingPlanChangeConfirmationIfCurrent(pending)
    }

    func clearStalePlanChangeConfirmationIfNeeded(after status: ManagedAccountStatus) {
        clearDivergentPendingPlanChangeIfNeeded(after: status)
        guard let confirmedTier = planChangeConfirmationTier else {
            return
        }
        guard let subscription = status.subscription,
              PaddlePlan(subscriptionPlan: subscription.plan) == confirmedTier,
              successfulPlanChangeStatuses.contains(subscription.status) else {
            clearPlanChangeConfirmation()
            return
        }
    }

    func trackPlanChangeUntilQuotaArrivesIfNeeded(
        _ status: ManagedAccountStatus?,
        tier: PaddlePlan,
        accountKey: String,
        settingsMessageGeneration: UInt64? = nil
    ) {
        guard let status,
              status.quota == nil,
              !managedAccountStatusIsFresh,
              managedAccountMatches(accountKey),
              statusConfirmsPlanChange(status, tier: tier) else {
            return
        }
        planChangeReconciliationGeneration &+= 1
        pendingPlanChangeReconciliation = PendingPlanChangeReconciliation(
            tier: tier,
            accountKey: accountKey,
            generation: planChangeReconciliationGeneration,
            settingsMessageGeneration: settingsMessageGeneration
        )
        scheduleManagedAccountStatusRefreshRetryAfterFailure()
    }

    func statusConfirmsTrackedPlanChange(_ status: ManagedAccountStatus) -> Bool {
        guard let pending = pendingPlanChangeReconciliation,
              pending.generation == planChangeReconciliationGeneration,
              managedAccountMatches(pending.accountKey) else {
            return false
        }
        return statusConfirmsPendingPlanChange(status, pending: pending)
    }

    func statusConfirmsPlanChange(_ status: ManagedAccountStatus?, tier: PaddlePlan) -> Bool {
        guard let status,
              let subscription = status.subscription,
              PaddlePlan(subscriptionPlan: subscription.plan) == tier,
              successfulPlanChangeStatuses.contains(subscription.status) else {
            return false
        }
        return true
    }

    func hasFreshConfirmedPlanChange(_ tier: PaddlePlan) -> Bool {
        guard managedAccountStatusIsFresh,
              let status = managedAccountStatus,
              statusConfirmsPlanChange(status, tier: tier) else {
            return false
        }
        return true
    }

    func scheduleQuotaRetryIfAcceptedWithoutQuota(_ status: ManagedAccountStatus?) {
        guard let status,
              status.quota == nil,
              !managedAccountStatusIsFresh else {
            return
        }
        scheduleManagedAccountStatusRefreshRetryAfterFailure()
    }

    private func clearPlanChangeConfirmation() {
        planChangeMessage = nil
        planChangeConfirmationTier = nil
        planChangeFailed = false
    }

    private func publishPendingPlanChangeConfirmationIfCurrent(_ pending: PendingPlanChangeReconciliation) {
        if let settingsMessageGeneration = pending.settingsMessageGeneration,
           !isCurrentSettingsTransientMessageGeneration(settingsMessageGeneration) {
            return
        }
        planChangeFailed = false
        planChangeMessage = Self.changePlanConfirmation(for: pending.tier)
        planChangeConfirmationTier = pending.tier
    }

    private func clearDivergentPendingPlanChangeIfNeeded(after status: ManagedAccountStatus) {
        guard let pending = pendingPlanChangeReconciliation,
              pending.generation == planChangeReconciliationGeneration,
              planChangeReconciliationTask == nil,
              !statusConfirmsPendingPlanChange(status, pending: pending),
              status.subscription != nil else {
            return
        }
        pendingPlanChangeReconciliation = nil
        if planChangeFailed || planChangeConfirmationTier == nil {
            clearPlanChangeConfirmation()
        }
    }

    private func statusConfirmsPendingPlanChange(
        _ status: ManagedAccountStatus,
        pending: PendingPlanChangeReconciliation
    ) -> Bool {
        statusConfirmsPlanChange(status, tier: pending.tier)
    }
}
