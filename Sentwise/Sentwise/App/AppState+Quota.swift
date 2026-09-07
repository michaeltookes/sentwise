import Foundation
import os

private let quotaLogger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedQuota")

struct ManagedAccountStatusRefreshOrdering {
    var startedGeneration: UInt64 = 0
    var acceptedGeneration: UInt64 = 0
    var successVersion: UInt64 = 0
}

private enum ManagedQuotaIngestionSource {
    case draftReport
    case statusRefresh
}

/// Managed-inference usage metering on `AppState` (backlog item 56b): mirroring
/// the latest quota into published state, refreshing it from `/v1/me`, and firing
/// the 50/75/100% weekly-usage alerts idempotently. Kept in its own file so
/// `AppState` stays within length limits.
extension AppState {

    /// Wires the usage-metering callbacks (item 56b): a usage-alert Open routes to
    /// Settings → AI Provider, and managed-quota reports (from the possibly
    /// off-main LLM layer) hop onto the main actor to update published state and
    /// fire alerts. Called once from `installExternalActionHandlers`.
    func wireUsageMeteringHandlers() {
        // A usage-alert "Open" now routes to the Subscription tab, where the usage
        // bar and plan live (item 73; usage moved there from the AI tab).
        notifier.onOpenUsageSettings = { [weak self] in
            self?.openSettingsHandler?(.subscription)
        }
        managedQuotaRelay.setAccountKeyProvider { [weak self] in
            guard let self, self.isManagedSignedIn else { return nil }
            return self.currentManagedUsageAccountKey
        }
        managedQuotaRelay.setHandler { [weak self] quota, accountKey in
            self?.ingestManagedQuota(quota, accountKey: accountKey)
        }
    }

    var currentManagedUsageAccountKey: String {
        let accountID = managedAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !accountID.isEmpty {
            return ManagedUsageAccountKey.make(from: accountID)
        }
        let sessionID = ((try? secrets.value(for: .managedSessionID)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let sessionID, !sessionID.isEmpty {
            return ManagedUsageAccountKey.make(from: "clerk-session:\(sessionID)")
        }
        return ManagedUsageAccountKey.make(from: "display:\(managedAccountEmail)")
    }

    func clearManagedQuotaCache() {
        managedQuota = nil
        managedAccountStatus = nil
        managedAccountStatusIsFresh = false
        managedAccountStatusRefreshOrdering.startedGeneration &+= 1
        managedAccountStatusRefreshOrdering.acceptedGeneration = managedAccountStatusRefreshOrdering.startedGeneration
        managedAccountStatusRefreshOrdering.successVersion &+= 1
        cancelScheduledManagedAccountStatusRefresh()
        cancelBillingReconciliation()
        billingReconciliationBaseline = nil
        managedQuotaAccountKey = nil
        clearCachedSubscriptionSnapshot()
        // Account-key aliases are identity migrations, not quota display cache.
        // Delayed callbacks still need them after sign-out.
    }

    /// Records the latest quota (from a `/v1/draft` response or a `/v1/me` fetch)
    /// into published state and fires any newly-crossed usage-threshold alerts.
    /// Idempotent per managed account + weekly window — a threshold fires once
    /// until the account changes or the window resets. Alerts are suppressed in
    /// Prowl hunt mode so hunts stay side-effect free; the display value still
    /// updates so the pane renders deterministically.
    func ingestManagedQuota(_ quota: ManagedQuota, accountKey explicitAccountKey: String? = nil) {
        ingestManagedQuota(quota, accountKey: explicitAccountKey, source: .draftReport)
    }

    private func ingestManagedQuota(
        _ quota: ManagedQuota,
        accountKey explicitAccountKey: String?,
        source: ManagedQuotaIngestionSource
    ) {
        let accountKey = resolvedManagedQuotaAccountKey(explicitAccountKey ?? currentManagedUsageAccountKey)
        guard ProwlHuntRuntime.current.isEnabled
            || (isManagedSignedIn && accountKey == currentManagedUsageAccountKey)
        else { return }
        guard shouldAcceptManagedQuota(quota, for: accountKey, source: source) else { return }

        managedQuotaAccountKey = accountKey
        managedQuota = quota

        guard !ProwlHuntRuntime.current.isEnabled else { return }

        let previous = usageAlertStore.loadState(for: accountKey)
        let outcome = UsageAlertEvaluator.evaluate(quota: quota, previous: previous, accountKey: accountKey)
        usageAlertStore.save(outcome.newState)
        for threshold in outcome.fire {
            notifier.notifyUsageAlert(UsageAlert.make(threshold: threshold, quota: quota, accountKey: accountKey))
        }
    }

    private func shouldAcceptManagedQuota(
        _ quota: ManagedQuota,
        for accountKey: String,
        source: ManagedQuotaIngestionSource
    ) -> Bool {
        guard managedQuotaAccountKey == accountKey, let current = managedQuota else {
            return true
        }
        if quota.resetsAt < current.resetsAt {
            return false
        }
        if quota.resetsAt == current.resetsAt {
            if source == .draftReport && quota.used < current.used {
                return false
            }
            let hasCapacityMetadataDifference = quotaHasCapacityMetadataDifference(quota, comparedWith: current)
            if source == .draftReport && hasCapacityMetadataDifference {
                return false
            }
            if hasCapacityMetadataDifference {
                return true
            }
            if quota.used < current.used {
                return false
            }
        }
        return true
    }

    private func quotaHasCapacityMetadataDifference(_ quota: ManagedQuota, comparedWith current: ManagedQuota) -> Bool {
        quota.unit != current.unit
            || quota.limit != current.limit
            || quota.tokenLimit != current.tokenLimit
            || quota.enforcement != current.enforcement
            || quota.extraPurchased != current.extraPurchased
    }

    private func resolvedManagedQuotaAccountKey(_ accountKey: String) -> String {
        managedQuotaAccountKeyAliases[accountKey] ?? accountKey
    }

    /// Refreshes the quota from `/v1/me`. Called at launch, on sign-in, and when
    /// the AI Provider settings pane opens. No-ops (silently) when there is no
    /// signed-in managed account. Transient errors keep the last known display
    /// value and schedule a bounded retry. In Prowl hunt mode the LLM service
    /// returns the deterministic stub with zero network.
    func refreshManagedQuota(scheduleRetryOnFailure: Bool = true) async {
        guard ProwlHuntRuntime.current.isEnabled || isManagedSignedIn else {
            return
        }
        managedAccountStatusRefreshOrdering.startedGeneration &+= 1
        let refreshGeneration = managedAccountStatusRefreshOrdering.startedGeneration
        let successVersionAtStart = managedAccountStatusRefreshOrdering.successVersion
        let accountKey = currentManagedUsageAccountKey
        do {
            // The reporter path already routes the fetched quota through
            // `ingestManagedQuota`; still ingest the return value directly so an
            // injected LLM double without a wired relay updates state too.
            if let status = try await llm.fetchManagedAccountStatus() {
                guard shouldAcceptManagedAccountStatusRefreshSuccess(
                    generation: refreshGeneration,
                    accountKey: accountKey
                ) else { return }
                managedAccountStatusRefreshOrdering.acceptedGeneration = refreshGeneration
                managedAccountStatusRefreshOrdering.successVersion &+= 1
                let snapshotBeforeAccountKeyBackfill = effectiveSubscriptionSnapshot
                // Mirror the full status (email/trial/subscription) for the
                // Subscription pane (item 73), even when `quota` is absent on an
                // older Worker build.
                managedAccountStatus = status
                markManagedAccountStatusFresh(from: status)
                scheduleManagedAccountStatusRefreshAfterSuccess(scheduleRetryIfStale: scheduleRetryOnFailure)
                let resolvedAccountKey = backfillManagedAccountIDIfNeeded(from: status, replacing: accountKey)
                preserveSubscriptionSnapshot(
                    snapshotBeforeBackfill: snapshotBeforeAccountKeyBackfill,
                    originalAccountKey: accountKey,
                    resolvedAccountKey: resolvedAccountKey
                )
                if let quota = status.quota {
                    ingestManagedQuota(quota, accountKey: resolvedAccountKey, source: .statusRefresh)
                }
                // Cache the last-known subscription for offline license grace (56c).
                recordSubscriptionSnapshot(from: status)
                resumeInboxWatchingAfterManagedReauthenticationIfNeeded()
                retryDeferredTranscriptFolderDeliveriesAfterManagedLicenseRefreshIfNeeded()
            } else {
                guard shouldApplyManagedAccountStatusRefreshFailure(
                    generation: refreshGeneration,
                    accountKey: accountKey,
                    successVersionAtStart: successVersionAtStart
                ) else { return }
                managedAccountStatusIsFresh = false
                if scheduleRetryOnFailure {
                    scheduleManagedAccountStatusRefreshRetryAfterFailure()
                }
            }
        } catch {
            guard shouldApplyManagedAccountStatusRefreshFailure(
                generation: refreshGeneration,
                accountKey: accountKey,
                successVersionAtStart: successVersionAtStart
            ) else { return }
            managedAccountStatusIsFresh = false
            // Metering is best-effort surfacing, never a blocking failure; a
            // managed 401 is reconciled by the normal draft/test paths.
            let signedOut = await reconcileManagedAccountState(after: error, provider: .managed)
            if shouldApplyManagedAccountStatusRefreshFailure(
                generation: refreshGeneration,
                accountKey: accountKey,
                successVersionAtStart: successVersionAtStart
            ),
               !signedOut,
               scheduleRetryOnFailure {
                scheduleManagedAccountStatusRefreshRetryAfterFailure()
            }
        }
    }

    private func preserveSubscriptionSnapshot(
        snapshotBeforeBackfill: SubscriptionSnapshot?,
        originalAccountKey: String,
        resolvedAccountKey: String
    ) {
        let snapshot = cachedSubscriptionSnapshot ?? snapshotBeforeBackfill
        if originalAccountKey != resolvedAccountKey, let snapshot {
            cacheSubscriptionSnapshot(snapshot)
        } else {
            cachedSubscriptionSnapshot = snapshot
        }
    }

    private func shouldAcceptManagedAccountStatusRefreshSuccess(generation: UInt64, accountKey: String) -> Bool {
        guard generation > managedAccountStatusRefreshOrdering.acceptedGeneration else { return false }
        guard ProwlHuntRuntime.current.isEnabled else {
            return isManagedSignedIn && accountKey == currentManagedUsageAccountKey
        }
        return true
    }

    private func shouldApplyManagedAccountStatusRefreshFailure(
        generation: UInt64,
        accountKey: String,
        successVersionAtStart: UInt64
    ) -> Bool {
        guard managedAccountStatusRefreshOrdering.successVersion == successVersionAtStart,
              generation > managedAccountStatusRefreshOrdering.acceptedGeneration else {
            return false
        }
        guard ProwlHuntRuntime.current.isEnabled else {
            return isManagedSignedIn && accountKey == currentManagedUsageAccountKey
        }
        return true
    }

    @discardableResult
    private func backfillManagedAccountIDIfNeeded(
        from status: ManagedAccountStatus,
        replacing previousAccountKey: String
    ) -> String {
        guard let stableAccountID = status.stableAccountIdentifier else {
            return previousAccountKey
        }

        let currentID = managedAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentID == stableAccountID {
            return currentManagedUsageAccountKey
        }
        guard currentID.isEmpty || currentID.hasPrefix("clerk-session:") else {
            return previousAccountKey
        }

        managedAccountID = stableAccountID
        let newAccountKey = currentManagedUsageAccountKey
        managedQuotaAccountKeyAliases[previousAccountKey] = newAccountKey
        usageAlertStore.migrateState(from: previousAccountKey, to: newAccountKey)
        googleOAuthInterestStore.migrateRegistration(from: previousAccountKey, to: newAccountKey)
        googleOAuthInterestRegistered = googleOAuthInterestStore.isRegistered(accountKey: newAccountKey)
        if managedQuotaAccountKey == previousAccountKey {
            managedQuotaAccountKey = newAccountKey
        }
        persistManagedAccountIDBackfill()
        return newAccountKey
    }

    private func persistManagedAccountIDBackfill() {
        do {
            try persistSettingsSync(buildSettings())
        } catch {
            quotaLogger.error("Failed to persist managed account id backfill: \(error.localizedDescription)")
        }
    }

    /// Whether the account is at or over its weekly allotment (drives the pane's
    /// "buy more usage" placeholder and the over-limit copy). `false` when the
    /// quota is unknown.
    var isManagedQuotaExhausted: Bool {
        guard let quota = managedQuota,
              managedQuotaAccountKey == currentManagedUsageAccountKey,
              quota.limit > 0 else { return false }
        return quota.used >= quota.limit
    }
}

/// Bridges managed-quota reports from the (possibly off-main) LLM layer onto the
/// main actor so `AppState` can update `@Published` state and fire usage alerts
/// (backlog item 56b). The handler is installed once, right after `AppState`
/// finishes initializing.
final class ManagedQuotaRelay: ManagedQuotaReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var accountKeyProvider: (@MainActor () -> String?)?
    private var handler: (@MainActor (ManagedQuota, String) -> Void)?

    func setAccountKeyProvider(_ provider: @escaping @MainActor () -> String?) {
        lock.withLock { self.accountKeyProvider = provider }
    }

    func setHandler(_ handler: @escaping @MainActor (ManagedQuota, String) -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// Synchronous snapshots of closures. Kept out of `async` functions because
    /// `NSLock.lock()` is unavailable from asynchronous contexts.
    private func currentAccountKeyProvider() -> (@MainActor () -> String?)? {
        lock.withLock { accountKeyProvider }
    }

    private func currentHandler() -> (@MainActor (ManagedQuota, String) -> Void)? {
        lock.withLock { handler }
    }

    func currentQuotaReportAccountKey() async -> String? {
        guard let provider = currentAccountKeyProvider() else { return nil }
        return await MainActor.run { provider() }
    }

    func reportQuota(_ quota: ManagedQuota, accountKey: String) async {
        guard let handler = currentHandler() else { return }
        await MainActor.run { handler(quota, accountKey) }
    }
}
