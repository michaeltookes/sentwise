import AppKit
import Foundation

private let paidManagedSubscriptionPlans: Set<ManagedSubscription.Plan> = [.starter, .pro, .unlimited, .team]
private let nonRecurringManagedSubscriptionPlans: Set<ManagedSubscription.Plan> = [.trial, .noPlan]
private let endedManagedSubscriptionStatuses: Set<ManagedSubscription.Status> = [.canceled, .lapsed]
private let managedAccountStatusFreshDuration = SubscriptionLicenseEvaluator.defaultGrace
private let managedAccountStatusRefreshLeadTime: TimeInterval = 60 * 60
private let managedAccountStatusRefreshRetryDelays: [UInt64] = [
    60_000_000_000,
    300_000_000_000,
    900_000_000_000,
    1_800_000_000_000,
    3_600_000_000_000
]

private typealias ManagedSubscriptionBillingState = (
    plan: ManagedSubscription.Plan,
    status: ManagedSubscription.Status
)

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
    /// the sign-in controls instead. Existing paid subscribers are routed through
    /// Paddle's billing portal so they modify the current subscription rather than
    /// opening a second recurring checkout.
    func presentBillingCheckout(plan: PaddlePlan? = nil) {
        guard isManagedSignedIn, !hasManageablePaidSubscription else { return }
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
    /// webhook-written subscription is reflected. Dismisses the sheet, then retries
    /// `/v1/me` with bounded backoff until the paid subscription is visible.
    func completeBillingCheckout(
        refreshRetryDelays: [UInt64] = [
            750_000_000,
            1_500_000_000,
            3_000_000_000,
            6_000_000_000
        ]
    ) async {
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
    }

    // MARK: - Manage billing

    /// The merchant-of-record billing-portal URL when the Worker provides one.
    /// Prefers the live status; falls back to the cached snapshot so the button
    /// still works from a last-known value while offline (item 56c).
    var manageBillingURL: URL? {
        let raw = managedAccountStatus?.subscription?.manageBillingURL
            ?? effectiveSubscriptionSnapshot?.manageBillingURL
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
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
        guard let state = currentSubscriptionBillingState else { return false }
        return state.status == .active && paidManagedSubscriptionPlans.contains(state.plan)
    }

    /// Whether there is an existing paid subscription that should be managed through
    /// Paddle's portal instead of starting a new recurring checkout. Unknown plan or
    /// lifecycle values are treated as existing subscriptions unless they are known
    /// trial/no-plan or ended states, which prevents duplicate checkouts when the
    /// Worker adds a paid tier or status before this app version knows that value.
    var hasManageablePaidSubscription: Bool {
        guard let state = currentSubscriptionBillingState,
              !nonRecurringManagedSubscriptionPlans.contains(state.plan),
              !endedManagedSubscriptionStatuses.contains(state.status) else {
            return false
        }
        return true
    }

    /// Whether to offer the subscribe/upgrade CTA. Offered whenever the account is
    /// not already tied to a current or indeterminate paid subscription — i.e. only
    /// when a new checkout can move the account forward without duplicating an
    /// existing Paddle subscription.
    var shouldOfferSubscribe: Bool {
        isManagedSignedIn && !hasManageablePaidSubscription
    }

    // MARK: - Offline license grace

    var managedAccountStatusIsFresh: Bool {
        get {
            guard let freshUntil = managedAccountStatusFreshUntil else { return false }
            return Date() < freshUntil
        }
        set {
            managedAccountStatusFreshUntil = newValue
                ? Date().addingTimeInterval(managedAccountStatusFreshDuration)
                : nil
        }
    }

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
    /// `/v1/me` status only after a successful refresh; when offline, unknown, or
    /// stale after a failed refresh it falls back to the cached snapshot within a
    /// grace window, so the app/UI never hard-fails offline.
    var managedLicense: SubscriptionLicense {
        let liveStatus = isOnline && managedAccountStatusIsFresh
            ? currentLiveSubscriptionStatus
            : nil
        return SubscriptionLicenseEvaluator.evaluate(
            liveStatus: liveStatus,
            cached: effectiveSubscriptionSnapshot
        )
    }

    /// Whether the active managed license permits LLM-backed app work. Grace is
    /// allowed; problem/unknown states are blocked before a managed request is made.
    var managedLicenseAllowsLLMRequests: Bool {
        guard !ProwlHuntRuntime.current.isEnabled else { return true }
        switch managedLicense {
        case .entitled, .grace:
            return true
        case .notEntitled, .unknown:
            return false
        }
    }

    var currentLLMProviderAllowsRequests: Bool {
        llmProviderKind != .managed || managedLicenseAllowsLLMRequests
    }

    var shouldResumeWatchingAfterManagedLicenseRecovery: Bool {
        llmProviderKind == .managed
            && isManagedSignedIn
            && isAccountConnected
            && isLLMConnected
            && !managedLicenseAllowsLLMRequests
    }

    func markManagedAccountStatusFresh(from status: ManagedAccountStatus) {
        let defaultFreshUntil = Date().addingTimeInterval(managedAccountStatusFreshDuration)
        if let trialEndsAt = trialFreshnessDeadline(from: status) {
            managedAccountStatusFreshUntil = min(defaultFreshUntil, trialEndsAt)
        } else {
            managedAccountStatusFreshUntil = defaultFreshUntil
        }
    }

    func refreshManagedQuotaIfLicenseStatusStale() async {
        guard llmProviderKind == .managed,
              isManagedSignedIn,
              isOnline,
              !managedAccountStatusIsFresh else {
            return
        }
        await refreshManagedQuota()
    }

    func waitToStartWatchingAfterManagedLicenseRefreshIfNeeded() {
        guard watchStatus == .idle,
              llmProviderKind == .managed,
              isAccountConnected,
              isLLMConnected,
              isManagedSignedIn,
              managedLicense == .unknown else {
            return
        }
        resumeWatchingAfterManagedReauth = true
    }

    func scheduleManagedAccountStatusRefreshBeforeExpiry() {
        cancelScheduledManagedAccountStatusRefresh()
        guard isManagedSignedIn,
              isOnline,
              let freshUntil = managedAccountStatusFreshUntil else {
            return
        }
        let refreshAt = freshUntil == currentTrialFreshnessDeadline
            ? freshUntil
            : freshUntil.addingTimeInterval(-managedAccountStatusRefreshLeadTime)
        let delay = max(0, refreshAt.timeIntervalSinceNow)
        managedAccountStatusRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            await self?.refreshManagedQuotaIfScheduled(freshUntil: freshUntil)
        }
    }

    func scheduleManagedAccountStatusRefreshRetryAfterFailure(delays: [UInt64]? = nil) {
        cancelScheduledManagedAccountStatusRefresh()
        let retryDelays = delays ?? managedAccountStatusRefreshRetryDelays
        guard isManagedSignedIn, isOnline, !retryDelays.isEmpty else { return }
        managedAccountStatusRefreshTask = Task { [weak self] in
            for delay in retryDelays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self else { return }
                let shouldContinue = await self.refreshManagedQuotaForRetry()
                if !shouldContinue { return }
            }
            await self?.finishManagedAccountStatusRefreshRetry()
        }
    }

    func cancelScheduledManagedAccountStatusRefresh() {
        managedAccountStatusRefreshTask?.cancel()
        managedAccountStatusRefreshTask = nil
    }

    /// Persists the last-known subscription/trial from a successful `/v1/me` so
    /// offline grace has something to fall back on.
    func recordSubscriptionSnapshot(from status: ManagedAccountStatus) {
        let snapshot = subscriptionSnapshot(from: status)
            ?? derivedTrialSubscriptionSnapshot(from: status)
            ?? legacyQuotaSubscriptionSnapshot(from: status)
        guard let snapshot else { return }
        cachedSubscriptionSnapshot = snapshot
        subscriptionCacheStore.save(snapshot, accountKey: currentManagedUsageAccountKey)
    }

    /// Clears the in-memory offline-grace snapshot (called on sign-out alongside
    /// the quota cache). The durable per-account store is cleared separately so a
    /// re-sign-in on the same account can still read its last-known entitlement.
    func clearCachedSubscriptionSnapshot() {
        cachedSubscriptionSnapshot = nil
    }

    private var currentSubscriptionBillingState: ManagedSubscriptionBillingState? {
        if let subscription = managedAccountStatus?.subscription {
            return (subscription.plan, subscription.status)
        }
        guard let snapshot = effectiveSubscriptionSnapshot,
              snapshot.source != .legacyQuota else {
            return nil
        }
        return (snapshot.plan, snapshot.status)
    }

    private var currentLiveSubscriptionStatus: ManagedSubscription.Status? {
        guard let status = managedAccountStatus else { return nil }
        if let subscriptionStatus = status.subscription?.status {
            return subscriptionStatus
        }
        if let trialStatus = derivedTrialSubscriptionState(from: status)?.status {
            return trialStatus
        }
        if status.quota != nil {
            return .active
        }
        return nil
    }

    private func refreshManagedQuotaIfScheduled(freshUntil: Date) async {
        guard managedAccountStatusFreshUntil == freshUntil,
              isManagedSignedIn,
              isOnline else {
            return
        }
        managedAccountStatusRefreshTask = nil
        await refreshManagedQuota()
    }

    private func refreshManagedQuotaForRetry() async -> Bool {
        guard isManagedSignedIn, isOnline, !managedAccountStatusIsFresh else {
            managedAccountStatusRefreshTask = nil
            return false
        }
        await refreshManagedQuota(scheduleRetryOnFailure: false)
        return isManagedSignedIn && isOnline && !managedAccountStatusIsFresh
    }

    private func finishManagedAccountStatusRefreshRetry() {
        if !managedAccountStatusIsFresh {
            managedAccountStatusRefreshTask = nil
        }
    }

    private var currentTrialFreshnessDeadline: Date? {
        guard let status = managedAccountStatus else { return nil }
        return trialFreshnessDeadline(from: status)
    }

    private func trialFreshnessDeadline(from status: ManagedAccountStatus) -> Date? {
        guard let state = currentSubscriptionState(from: status),
              state.plan == .trial,
              state.status == .trialing else {
            return nil
        }
        return status.trial?.endsAt
    }

    private func subscriptionSnapshot(from status: ManagedAccountStatus) -> SubscriptionSnapshot? {
        guard let subscription = status.subscription else { return nil }
        let renewsAt = subscription.renewsAt ?? (subscription.plan == .trial ? status.trial?.endsAt : nil)
        return SubscriptionSnapshot(
            plan: subscription.plan,
            status: subscription.status,
            renewsAt: renewsAt,
            manageBillingURL: subscription.manageBillingURL,
            capturedAt: Date()
        )
    }

    private func derivedTrialSubscriptionSnapshot(from status: ManagedAccountStatus) -> SubscriptionSnapshot? {
        guard let state = derivedTrialSubscriptionState(from: status) else { return nil }
        return SubscriptionSnapshot(
            plan: state.plan,
            status: state.status,
            renewsAt: status.trial?.endsAt,
            capturedAt: Date(),
            source: .trial
        )
    }

    private func legacyQuotaSubscriptionSnapshot(from status: ManagedAccountStatus) -> SubscriptionSnapshot? {
        guard status.subscription == nil,
              status.trial == nil,
              status.quota != nil else {
            return nil
        }
        return SubscriptionSnapshot(plan: .unknown, status: .active, capturedAt: Date(), source: .legacyQuota)
    }

    private func currentSubscriptionState(from status: ManagedAccountStatus) -> ManagedSubscriptionBillingState? {
        if let subscription = status.subscription {
            return (subscription.plan, subscription.status)
        }
        return derivedTrialSubscriptionState(from: status)
    }

    private func derivedTrialSubscriptionState(from status: ManagedAccountStatus) -> ManagedSubscriptionBillingState? {
        guard let trial = status.trial else { return nil }
        let isActive = trial.active ?? trial.endsAt.map { $0 > Date() } ?? false
        return (.trial, isActive ? .trialing : .lapsed)
    }
}
