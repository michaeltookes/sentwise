import AppKit
import Foundation

extension AppState {
    /// The merchant-of-record billing-portal URL from the current Worker status.
    /// Paddle portal URLs are temporary, so durable snapshots are not opener sources.
    var manageBillingURL: URL? {
        validatedManageBillingURL(from: managedAccountStatus?.subscription?.manageBillingURL)
    }

    /// Whether "Manage billing" should be enabled. Cached paid-subscription
    /// snapshots keep the CTA available, but opening still fetches a fresh URL.
    var canManageBilling: Bool {
        isOnline && (manageBillingURL != nil || hasManageablePaidSubscription)
    }

    /// Opens the Paddle customer portal in the default browser (item 56c).
    func openManageBilling(openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }) async {
        guard canManageBilling, isManagedSignedIn, isOnline else { return }
        managedAccountStatusIsFresh = false
        cancelScheduledManagedAccountStatusRefresh()

        let successVersionBeforeRefresh = managedAccountStatusRefreshOrdering.successVersion
        await refreshManagedQuota(scheduleRetryOnFailure: false)
        guard managedAccountStatusRefreshOrdering.successVersion > successVersionBeforeRefresh,
              let url = manageBillingURL else {
            return
        }

        billingReconciliationBaseline = currentBillingReconciliationSnapshot
        billingPortalRefreshPending = true
        managedAccountStatusIsFresh = false
        cancelScheduledManagedAccountStatusRefresh()
        openURL(url)
    }

    private func validatedManageBillingURL(from rawValue: String?) -> URL? {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
