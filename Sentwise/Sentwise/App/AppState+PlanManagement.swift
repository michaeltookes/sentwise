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

private let planChangeBackgroundReconcileRetryDelays: [UInt64] = [
    30_000_000_000,
    120_000_000_000,
    300_000_000_000,
    900_000_000_000,
    1_800_000_000_000
]

private let successfulPlanChangeStatuses: Set<ManagedSubscription.Status> = [.active, .pastDue]

struct PendingPlanChangeReconciliation {
    let tier: PaddlePlan
    let accountKey: String
    let generation: UInt64
}

/// In-app plan management on `AppState` (backlog item 90): the account's current
/// purchasable tier, the upgrade/downgrade change-plan flow (a Paddle
/// subscription update with proration, reconciled against `/v1/me`), and the
/// billing-only confirmation/error copy. Cancellation and the on-demand
/// manage-billing fetch live in `AppState+BillingPortal`.
extension AppState {

    /// The account's current purchasable tier (Starter / Pro / Unlimited), or nil
    /// when the account is on a lifecycle plan that isn't one of the cards (trial /
    /// none / team / unknown). A live `/v1/me` subscription is authoritative even
    /// when it maps to no card; falls back to offline grace only when live status
    /// omits subscription data.
    var currentSubscriptionPlanTier: PaddlePlan? {
        if let subscription = managedAccountStatus?.subscription {
            return PaddlePlan(subscriptionPlan: subscription.plan)
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
        isManagedSignedIn && hasManageablePaidSubscription && currentSubscriptionPlanTier != nil
    }

    /// Switches the subscription to `tier` (item 90). No-op when not signed in,
    /// offline, already changing, not on a known tier, or already on `tier`. Calls
    /// `POST /v1/paddle/change-plan` (a prorated Paddle subscription update), then
    /// polls `/v1/me` until the account's tier flips, and finally surfaces a
    /// billing-only confirmation. Endpoint errors map to friendly, billing-only
    /// copy in `planChangeMessage`.
    func changePlan(
        to tier: PaddlePlan,
        reconcileRetryDelays: [UInt64] = planChangeReconcileRetryDelays,
        backgroundReconcileRetryDelays: [UInt64] = planChangeBackgroundReconcileRetryDelays
    ) async {
        guard isManagedSignedIn, isOnline, !isChangingPlan, !isManagingBilling,
              hasManageablePaidSubscription,
              let current = currentSubscriptionPlanTier, current != tier else {
            return
        }
        let accountKey = currentManagedUsageAccountKey
        planChangeOperationGeneration &+= 1
        let operationGeneration = planChangeOperationGeneration
        cancelPlanChangeReconciliation()
        planChangeMessage = nil
        planChangeFailed = false
        isChangingPlan = true
        changingPlanTier = tier
        defer {
            if isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) {
                isChangingPlan = false
                changingPlanTier = nil
            }
        }

        let priceID = PaddleConfig.active.priceID(for: tier)
        let change: PaddlePlanChange
        let sessionAccountKey = currentManagedSessionAccountKey ?? accountKey
        do {
            change = try await llm.changeManagedPlan(priceID: priceID, expectedAccountKey: sessionAccountKey)
        } catch {
            guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return }
            await reconcileManagedAccountState(after: error, provider: .managed)
            guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return }
            planChangeFailed = true
            planChangeMessage = Self.changePlanErrorMessage(for: error)
            return
        }
        guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return }

        let observedTargetTier = await reconcilePlanChange(
            to: tier,
            accountKey: accountKey,
            operationGeneration: operationGeneration,
            retryDelays: reconcileRetryDelays
        )
        guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return }
        if !observedTargetTier {
            guard applyValidatedPlanChange(change, expectedTier: tier, accountKey: accountKey) else {
                planChangeFailed = true
                planChangeMessage = Self.changePlanConfirmationPendingMessage()
                return
            }
            schedulePlanChangeReconciliation(
                to: tier,
                accountKey: accountKey,
                validatedChange: change,
                retryDelays: backgroundReconcileRetryDelays
            )
        }
        planChangeFailed = false
        planChangeMessage = Self.changePlanConfirmation(for: tier)
    }

    /// Polls `/v1/me` after a successful change-plan call until the account's tier
    /// becomes `tier` (item 90), so the pane reflects the new plan. Stops early
    /// once the tier flips. In Prowl hunt mode `refreshManagedQuota` is a
    /// deterministic no-op, so this neither polls the network nor blocks.
    func reconcilePlanChange(
        to tier: PaddlePlan,
        accountKey: String,
        operationGeneration: UInt64,
        retryDelays: [UInt64]
    ) async -> Bool {
        await refreshManagedQuota()
        guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return false }
        if hasFreshLivePlanAndQuota(tier) { return true }
        // Hunt mode never flips the deterministic stub tier — don't spin the poll.
        guard !ProwlHuntRuntime.current.isEnabled else { return false }

        for delay in retryDelays {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return false
            }
            guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey),
                  isOnline else { return false }
            await refreshManagedQuota()
            guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return false }
            if hasFreshLivePlanAndQuota(tier) { return true }
        }
        return false
    }

    @discardableResult
    private func applyValidatedPlanChange(
        _ change: PaddlePlanChange,
        expectedTier tier: PaddlePlan,
        accountKey: String
    ) -> Bool {
        guard managedAccountMatches(accountKey),
              let changedTier = PaddlePlan(subscriptionPlan: change.plan),
              changedTier == tier,
              successfulPlanChangeStatuses.contains(change.status) else {
            return false
        }

        let previousStatus = managedAccountStatus
        let subscription = ManagedSubscription(
            plan: change.plan,
            status: change.status,
            renewsAt: previousStatus?.subscription?.renewsAt,
            manageBillingURL: previousStatus?.subscription?.manageBillingURL
        )
        let status = ManagedAccountStatus(
            userID: previousStatus?.userID ?? managedClerkUserID,
            email: previousStatus?.email ?? managedAccountEmail,
            trial: previousStatus?.trial,
            quota: previousStatus?.quota ?? managedQuota,
            subscription: subscription
        )
        supersedeInFlightManagedAccountStatusRefreshes()
        managedAccountStatus = status
        managedAccountStatusIsFresh = false
        cancelScheduledManagedAccountStatusRefresh()
        recordSubscriptionSnapshot(from: status)
        return true
    }

    func cancelPlanChangeReconciliation() {
        planChangeReconciliationGeneration &+= 1
        planChangeReconciliationTask?.cancel()
        planChangeReconciliationTask = nil
        pendingPlanChangeReconciliation = nil
    }

    func resetPlanManagementState() {
        cancelPlanChangeReconciliation()
        manageBillingOperationGeneration &+= 1
        planChangeOperationGeneration &+= 1
        isManagingBilling = false
        manageBillingMessage = nil
        isChangingPlan = false
        changingPlanTier = nil
        planChangeMessage = nil
        planChangeFailed = false
    }

    func managedAccountMatches(_ accountKey: String) -> Bool {
        guard isManagedSignedIn else { return false }
        let currentAccountKey = currentManagedUsageAccountKey
        return accountKey == currentAccountKey || managedQuotaAccountKeyAliases[accountKey] == currentAccountKey
    }

    private func isCurrentPlanChangeOperation(_ generation: UInt64, accountKey: String) -> Bool {
        planChangeOperationGeneration == generation && managedAccountMatches(accountKey)
    }

    private func schedulePlanChangeReconciliation(
        to tier: PaddlePlan,
        accountKey: String,
        validatedChange change: PaddlePlanChange,
        retryDelays: [UInt64]
    ) {
        cancelPlanChangeReconciliation()
        guard managedAccountMatches(accountKey), !retryDelays.isEmpty else { return }
        planChangeReconciliationGeneration &+= 1
        let generation = planChangeReconciliationGeneration
        pendingPlanChangeReconciliation = PendingPlanChangeReconciliation(
            tier: tier,
            accountKey: accountKey,
            generation: generation
        )
        planChangeReconciliationTask = Task { [weak self] in
            for (index, delay) in retryDelays.enumerated() {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self else { return }
                let isFinalAttempt = index == retryDelays.count - 1
                let shouldContinue = await self.refreshPlanChangeReconciliation(
                    to: tier,
                    accountKey: accountKey,
                    validatedChange: change,
                    generation: generation,
                    isFinalAttempt: isFinalAttempt
                )
                if !shouldContinue { return }
            }
            self?.finishPlanChangeReconciliation(generation: generation)
        }
    }

    private func refreshPlanChangeReconciliation(
        to tier: PaddlePlan,
        accountKey: String,
        validatedChange change: PaddlePlanChange,
        generation: UInt64,
        isFinalAttempt: Bool
    ) async -> Bool {
        guard planChangeReconciliationGeneration == generation,
              managedAccountMatches(accountKey) else { return false }
        guard isOnline else { return true }
        await refreshManagedQuota(
            scheduleRetryOnFailure: false,
            deferPendingPlanChangeStatus: !isFinalAttempt
        )
        guard planChangeReconciliationGeneration == generation,
              managedAccountMatches(accountKey) else { return false }
        if hasFreshLivePlanAndQuota(tier) {
            finishPlanChangeReconciliation(generation: generation)
            return false
        }
        if isFinalAttempt {
            planChangeFailed = true
            planChangeMessage = Self.changePlanConfirmationPendingMessage()
            finishPlanChangeReconciliation(generation: generation)
            if !managedAccountStatusIsFresh {
                scheduleManagedAccountStatusRefreshRetryAfterFailure()
            }
            return false
        }
        guard applyValidatedPlanChange(change, expectedTier: tier, accountKey: accountKey) else {
            finishPlanChangeReconciliation(generation: generation)
            return false
        }
        return true
    }

    private func finishPlanChangeReconciliation(generation: UInt64) {
        guard planChangeReconciliationGeneration == generation else { return }
        planChangeReconciliationTask?.cancel()
        planChangeReconciliationTask = nil
        if pendingPlanChangeReconciliation?.generation == generation {
            pendingPlanChangeReconciliation = nil
        }
    }

    func shouldDeferStatusRefreshForPendingPlanChange(_ status: ManagedAccountStatus) -> Bool {
        guard let pending = pendingPlanChangeReconciliation,
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
        finishPlanChangeReconciliation(generation: pending.generation)
    }

    private func statusConfirmsPendingPlanChange(
        _ status: ManagedAccountStatus,
        pending: PendingPlanChangeReconciliation
    ) -> Bool {
        guard let subscription = status.subscription,
              PaddlePlan(subscriptionPlan: subscription.plan) == pending.tier,
              successfulPlanChangeStatuses.contains(subscription.status),
              status.quota != nil else {
            return false
        }
        return true
    }

    private func hasFreshLivePlanAndQuota(_ tier: PaddlePlan) -> Bool {
        guard managedAccountStatusIsFresh,
              let status = managedAccountStatus,
              let subscription = status.subscription,
              let currentTier = PaddlePlan(subscriptionPlan: subscription.plan),
              currentTier == tier,
              successfulPlanChangeStatuses.contains(subscription.status),
              status.quota != nil else {
            return false
        }
        return true
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

    static func changePlanConfirmationPendingMessage() -> String {
        "We couldn't confirm the plan switch yet. Check your subscription again before trying another change."
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
