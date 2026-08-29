import Foundation

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
        ManagedUsageAccountKey.make(from: managedAccountEmail)
    }

    func clearManagedQuotaCache() {
        managedQuota = nil
        managedQuotaAccountKey = nil
    }

    /// Records the latest quota (from a `/v1/draft` response or a `/v1/me` fetch)
    /// into published state and fires any newly-crossed usage-threshold alerts.
    /// Idempotent per managed account + weekly window — a threshold fires once
    /// until the account changes or the window resets. Alerts are suppressed in
    /// Prowl hunt mode so hunts stay side-effect free; the display value still
    /// updates so the pane renders deterministically.
    func ingestManagedQuota(_ quota: ManagedQuota, accountKey explicitAccountKey: String? = nil) {
        let accountKey = explicitAccountKey ?? currentManagedUsageAccountKey
        guard ProwlHuntRuntime.current.isEnabled
            || (isManagedSignedIn && accountKey == currentManagedUsageAccountKey)
        else { return }

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
            if let quota = try await llm.fetchManagedQuota() {
                guard ProwlHuntRuntime.current.isEnabled
                    || (isManagedSignedIn && accountKey == currentManagedUsageAccountKey)
                else { return }
                ingestManagedQuota(quota, accountKey: accountKey)
            }
        } catch {
            // Metering is best-effort surfacing, never a blocking failure; a
            // managed 401 is reconciled by the normal draft/test paths.
            await reconcileManagedAccountState(after: error, provider: .managed)
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
    private var handler: (@MainActor (ManagedQuota, String?) -> Void)?

    func setAccountKeyProvider(_ provider: @escaping @MainActor () -> String?) {
        lock.withLock { self.accountKeyProvider = provider }
    }

    func setHandler(_ handler: @escaping @MainActor (ManagedQuota, String?) -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// Synchronous snapshots of closures. Kept out of `async` functions because
    /// `NSLock.lock()` is unavailable from asynchronous contexts.
    private func currentAccountKeyProvider() -> (@MainActor () -> String?)? {
        lock.withLock { accountKeyProvider }
    }

    private func currentHandler() -> (@MainActor (ManagedQuota, String?) -> Void)? {
        lock.withLock { handler }
    }

    func currentQuotaReportAccountKey() async -> String? {
        guard let provider = currentAccountKeyProvider() else { return nil }
        return await MainActor.run { provider() }
    }

    func reportQuota(_ quota: ManagedQuota, accountKey: String?) async {
        guard let handler = currentHandler() else { return }
        await MainActor.run { handler(quota, accountKey) }
    }
}
