import Foundation
import os

private let quotaLogger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedQuota")

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
        notifier.onOpenUsageSettings = { [weak self] in
            self?.openSettingsHandler?(.ai)
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
        managedQuotaAccountKey = nil
        managedQuotaAccountKeyAliases.removeAll()
    }

    /// Records the latest quota (from a `/v1/draft` response or a `/v1/me` fetch)
    /// into published state and fires any newly-crossed usage-threshold alerts.
    /// Idempotent per managed account + weekly window — a threshold fires once
    /// until the account changes or the window resets. Alerts are suppressed in
    /// Prowl hunt mode so hunts stay side-effect free; the display value still
    /// updates so the pane renders deterministically.
    func ingestManagedQuota(_ quota: ManagedQuota, accountKey explicitAccountKey: String? = nil) {
        let accountKey = resolvedManagedQuotaAccountKey(explicitAccountKey ?? currentManagedUsageAccountKey)
        guard ProwlHuntRuntime.current.isEnabled
            || (isManagedSignedIn && accountKey == currentManagedUsageAccountKey)
        else { return }
        guard shouldAcceptManagedQuota(quota, for: accountKey) else { return }

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

    private func shouldAcceptManagedQuota(_ quota: ManagedQuota, for accountKey: String) -> Bool {
        guard managedQuotaAccountKey == accountKey, let current = managedQuota else {
            return true
        }
        if quota.resetsAt < current.resetsAt {
            return false
        }
        if quota.resetsAt == current.resetsAt, quota.used < current.used {
            return false
        }
        return true
    }

    private func resolvedManagedQuotaAccountKey(_ accountKey: String) -> String {
        managedQuotaAccountKeyAliases[accountKey] ?? accountKey
    }

    /// Refreshes the quota from `/v1/me`. Called at launch, on sign-in, and when
    /// the AI Provider settings pane opens. No-ops (silently) when there is no
    /// signed-in managed account, or on any transient error — the display simply
    /// keeps its last known value. In Prowl hunt mode the LLM service returns the
    /// deterministic stub with zero network.
    func refreshManagedQuota() async {
        guard ProwlHuntRuntime.current.isEnabled || isManagedSignedIn else {
            return
        }
        let accountKey = currentManagedUsageAccountKey
        do {
            // The reporter path already routes the fetched quota through
            // `ingestManagedQuota`; still ingest the return value directly so an
            // injected LLM double without a wired relay updates state too.
            if let status = try await llm.fetchManagedAccountStatus() {
                guard ProwlHuntRuntime.current.isEnabled
                    || (isManagedSignedIn && accountKey == currentManagedUsageAccountKey)
                else { return }
                let resolvedAccountKey = backfillManagedAccountIDIfNeeded(
                    from: status,
                    replacing: accountKey
                )
                if let quota = status.quota {
                    ingestManagedQuota(quota, accountKey: resolvedAccountKey)
                }
            }
        } catch {
            // Metering is best-effort surfacing, never a blocking failure; a
            // managed 401 is reconciled by the normal draft/test paths.
            await reconcileManagedAccountState(after: error, provider: .managed)
        }
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
