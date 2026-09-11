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

let successfulPlanChangeStatuses: Set<ManagedSubscription.Status> = [.active, .pastDue]

struct PendingPlanChangeReconciliation {
    let tier: PaddlePlan
    let accountKey: String
    let generation: UInt64
    let settingsMessageGeneration: UInt64?

    init(
        tier: PaddlePlan,
        accountKey: String,
        generation: UInt64,
        settingsMessageGeneration: UInt64? = nil
    ) {
        self.tier = tier
        self.accountKey = accountKey
        self.generation = generation
        self.settingsMessageGeneration = settingsMessageGeneration
    }
}

private struct ScheduledPlanChangeReconciliation {
    let tier: PaddlePlan
    let accountKey: String
    let change: PaddlePlanChange
    let generation: UInt64
    let settingsMessageGeneration: UInt64
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
        hasPlanChangeablePaidSubscription
    }

    /// Whether direct in-app plan switching can start. Billing management remains
    /// available for indeterminate paid subscriptions; plan changes require a
    /// lifecycle status the confirmation/reconciliation path can validate.
    var canChangeManagedPlan: Bool {
        isManagedSignedIn
            && isOnline
            && !isChangingPlan
            && !isManagingBilling
            && hasPlanChangeablePaidSubscription
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
        guard canChangeManagedPlan,
              let current = currentSubscriptionPlanTier, current != tier else {
            return
        }
        let settingsMessageGeneration = settingsTransientMessageGeneration
        let accountKey = currentManagedUsageAccountKey
        planChangeOperationGeneration &+= 1
        let operationGeneration = planChangeOperationGeneration
        cancelPlanChangeReconciliation()
        clearPlanChangeMessageState()
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
            await reconcileManagedAccountState(after: error, provider: .managed, messageSurface: .settings)
            guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return }
            publishPlanChangeFailure(
                Self.changePlanErrorMessage(for: error),
                settingsMessageGeneration: settingsMessageGeneration
            )
            return
        }
        guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return }

        let observedTargetTier = await reconcilePlanChange(
            to: tier,
            accountKey: accountKey,
            operationGeneration: operationGeneration,
            retryDelays: reconcileRetryDelays,
            settingsMessageGeneration: settingsMessageGeneration
        )
        guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return }
        if !observedTargetTier {
            guard applyValidatedPlanChange(change, expectedTier: tier, accountKey: accountKey) else {
                publishPlanChangeFailure(
                    Self.changePlanConfirmationPendingMessage(),
                    settingsMessageGeneration: settingsMessageGeneration
                )
                return
            }
            schedulePlanChangeReconciliation(
                to: tier,
                accountKey: accountKey,
                validatedChange: change,
                retryDelays: backgroundReconcileRetryDelays,
                settingsMessageGeneration: settingsMessageGeneration
            )
        }
        publishPlanChangeConfirmation(for: tier, settingsMessageGeneration: settingsMessageGeneration)
    }

    /// Polls `/v1/me` after a successful change-plan call until the account's tier
    /// becomes `tier` (item 90), so the pane reflects the new plan. Stops early
    /// once the tier flips. In Prowl hunt mode `refreshManagedQuota` is a
    /// deterministic no-op, so this neither polls the network nor blocks.
    func reconcilePlanChange(
        to tier: PaddlePlan,
        accountKey: String,
        operationGeneration: UInt64,
        retryDelays: [UInt64],
        settingsMessageGeneration: UInt64? = nil
    ) async -> Bool {
        var refreshedStatus = await refreshManagedQuota(requireQuotaForFreshStatus: true)
        guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return false }
        if statusConfirmsPlanChange(refreshedStatus, tier: tier) {
            trackPlanChangeUntilQuotaArrivesIfNeeded(
                refreshedStatus,
                tier: tier,
                accountKey: accountKey,
                settingsMessageGeneration: settingsMessageGeneration
            )
            return true
        }
        if hasFreshConfirmedPlanChange(tier) {
            return true
        }
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
            refreshedStatus = await refreshManagedQuota(requireQuotaForFreshStatus: true)
            guard isCurrentPlanChangeOperation(operationGeneration, accountKey: accountKey) else { return false }
            if statusConfirmsPlanChange(refreshedStatus, tier: tier) {
                trackPlanChangeUntilQuotaArrivesIfNeeded(
                    refreshedStatus,
                    tier: tier,
                    accountKey: accountKey,
                    settingsMessageGeneration: settingsMessageGeneration
                )
                return true
            }
            if hasFreshConfirmedPlanChange(tier) {
                return true
            }
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
        clearPlanChangeMessageState()
    }

    func managedAccountMatches(_ accountKey: String) -> Bool {
        guard isManagedSignedIn else { return false }
        let currentAccountKey = currentManagedUsageAccountKey
        return accountKey == currentAccountKey || managedQuotaAccountKeyAliases[accountKey] == currentAccountKey
    }

    private func isCurrentPlanChangeOperation(_ generation: UInt64, accountKey: String) -> Bool {
        planChangeOperationGeneration == generation && managedAccountMatches(accountKey)
    }

    private func clearPlanChangeMessageState() {
        planChangeMessage = nil
        planChangeConfirmationTier = nil
        planChangeFailed = false
    }

    private func publishPlanChangeFailure(_ message: String, settingsMessageGeneration: UInt64) {
        guard isCurrentSettingsTransientMessageGeneration(settingsMessageGeneration) else { return }
        planChangeFailed = true
        planChangeMessage = message
        planChangeConfirmationTier = nil
    }

    private func publishPlanChangeConfirmation(for tier: PaddlePlan, settingsMessageGeneration: UInt64) {
        guard isCurrentSettingsTransientMessageGeneration(settingsMessageGeneration) else { return }
        planChangeFailed = false
        planChangeMessage = Self.changePlanConfirmation(for: tier)
        planChangeConfirmationTier = tier
    }

    private func schedulePlanChangeReconciliation(
        to tier: PaddlePlan,
        accountKey: String,
        validatedChange change: PaddlePlanChange,
        retryDelays: [UInt64],
        settingsMessageGeneration: UInt64
    ) {
        cancelPlanChangeReconciliation()
        guard managedAccountMatches(accountKey), !retryDelays.isEmpty else { return }
        planChangeReconciliationGeneration &+= 1
        let generation = planChangeReconciliationGeneration
        pendingPlanChangeReconciliation = PendingPlanChangeReconciliation(
            tier: tier,
            accountKey: accountKey,
            generation: generation,
            settingsMessageGeneration: settingsMessageGeneration
        )
        let context = ScheduledPlanChangeReconciliation(
            tier: tier,
            accountKey: accountKey,
            change: change,
            generation: generation,
            settingsMessageGeneration: settingsMessageGeneration
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
                    context,
                    isFinalAttempt: isFinalAttempt
                )
                if !shouldContinue { return }
            }
            self?.finishPlanChangeReconciliation(generation: generation)
        }
    }

    private func refreshPlanChangeReconciliation(
        _ context: ScheduledPlanChangeReconciliation,
        isFinalAttempt: Bool
    ) async -> Bool {
        guard planChangeReconciliationGeneration == context.generation,
              managedAccountMatches(context.accountKey) else { return false }
        guard isOnline else { return true }
        let refreshedStatus = await refreshManagedQuota(
            scheduleRetryOnFailure: false,
            deferPendingPlanChangeStatus: !isFinalAttempt,
            requireQuotaForFreshStatus: true
        )
        guard planChangeReconciliationGeneration == context.generation,
              managedAccountMatches(context.accountKey) else { return false }
        if statusConfirmsPlanChange(refreshedStatus, tier: context.tier) || hasFreshConfirmedPlanChange(context.tier) {
            let isWaitingForQuota = refreshedStatus?.quota == nil && !managedAccountStatusIsFresh
            scheduleQuotaRetryIfAcceptedWithoutQuota(refreshedStatus)
            finishPlanChangeReconciliation(
                generation: context.generation,
                preservePendingConfirmation: isWaitingForQuota
            )
            return false
        }
        if isFinalAttempt {
            publishPlanChangeFailure(
                Self.changePlanConfirmationPendingMessage(),
                settingsMessageGeneration: context.settingsMessageGeneration
            )
            pendingPlanChangeReconciliation = PendingPlanChangeReconciliation(
                tier: context.tier,
                accountKey: context.accountKey,
                generation: context.generation,
                settingsMessageGeneration: context.settingsMessageGeneration
            )
            finishPlanChangeReconciliation(generation: context.generation, preservePendingConfirmation: true)
            if !managedAccountStatusIsFresh {
                scheduleManagedAccountStatusRefreshRetryAfterFailure()
            }
            return false
        }
        guard applyValidatedPlanChange(context.change, expectedTier: context.tier, accountKey: context.accountKey) else {
            finishPlanChangeReconciliation(generation: context.generation)
            return false
        }
        return true
    }

    private var hasPlanChangeablePaidSubscription: Bool {
        guard isManagedSignedIn,
              hasManageablePaidSubscription,
              currentSubscriptionPlanTier != nil,
              let status = currentPlanManagementSubscriptionStatus,
              successfulPlanChangeStatuses.contains(status) else {
            return false
        }
        return true
    }

    private var currentPlanManagementSubscriptionStatus: ManagedSubscription.Status? {
        if let subscription = managedAccountStatus?.subscription {
            return subscription.status
        }
        guard let snapshot = effectiveSubscriptionSnapshot,
              PaddlePlan(subscriptionPlan: snapshot.plan) != nil else {
            return nil
        }
        return snapshot.status
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
