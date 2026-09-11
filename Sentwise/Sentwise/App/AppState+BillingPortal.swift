import AppKit
import Foundation

extension AppState {
    /// The merchant-of-record billing-portal URL captured on the current Worker
    /// status. Paddle portal URLs are short-lived, so this snapshot is **not** an
    /// opener source (it is nil in sandbox — the dead-button bug in item 90);
    /// `openManageBilling` fetches a fresh URL on demand instead. Retained for the
    /// entitlement-error path, which reads the raw stored value directly.
    var manageBillingURL: URL? {
        validatedManageBillingURL(from: managedAccountStatus?.subscription?.manageBillingURL)
    }

    /// Whether "Manage billing" should be enabled. Driven by whether the account
    /// has a manageable paid subscription and no billing operation is in flight
    /// (item 90) — no longer gated on a stored URL, because the URL is fetched
    /// fresh on tap.
    var canManageBilling: Bool {
        isOnline && hasManageablePaidSubscription && !isManagingBilling && !isChangingPlan
    }

    /// Opens the Paddle customer portal in the default browser (items 56c, 90).
    /// Fetches a **fresh** management URL on demand via
    /// `GET /v1/paddle/manage-billing` rather than trusting the (often-empty)
    /// webhook-stored URL. Never leaves an enabled control that silently no-ops:
    /// on a failed/empty fetch it surfaces `manageBillingMessage` inline. Pass
    /// `.cancel` to open the Paddle cancellation flow instead of the portal home.
    func openManageBilling(
        action: PaddleBillingAction? = nil,
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) async {
        guard isManagedSignedIn, canManageBilling else { return }
        let settingsMessageGeneration = settingsTransientMessageGeneration
        let accountKey = currentManagedUsageAccountKey
        manageBillingOperationGeneration &+= 1
        let operationGeneration = manageBillingOperationGeneration
        manageBillingMessage = nil
        isManagingBilling = true
        defer {
            if isCurrentManageBillingOperation(operationGeneration, accountKey: accountKey) {
                isManagingBilling = false
            }
        }

        let url: URL
        do {
            url = try await llm.fetchManageBillingURL(action: action)
        } catch {
            guard isCurrentManageBillingOperation(operationGeneration, accountKey: accountKey) else { return }
            await reconcileManagedAccountState(after: error, provider: .managed)
            guard isCurrentManageBillingOperation(operationGeneration, accountKey: accountKey) else { return }
            guard isCurrentSettingsTransientMessageGeneration(settingsMessageGeneration) else { return }
            manageBillingMessage = Self.manageBillingErrorMessage(for: error)
            return
        }
        guard isCurrentManageBillingOperation(operationGeneration, accountKey: accountKey) else { return }

        // In a Prowl accessibility hunt the URL is a deterministic stub and we must
        // not actually launch a browser; the control is still reachable/labelled.
        guard !ProwlHuntRuntime.current.isEnabled else { return }

        // Returning from the portal should re-pull status so a change made there is
        // reflected; arm the same refresh the checkout path uses.
        billingReconciliationBaseline = currentBillingReconciliationSnapshot
        billingPortalRefreshPending = true
        managedAccountStatusIsFresh = false
        cancelScheduledManagedAccountStatusRefresh()
        openURL(url)
    }

    /// Opens the Paddle cancellation flow (item 90) via
    /// `GET /v1/paddle/manage-billing?action=cancel`. The `canceled`/`lapsed`
    /// states the flow produces are already handled by the pane.
    func cancelSubscription(openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }) async {
        await openManageBilling(action: .cancel, openURL: openURL)
    }

    /// Billing-only copy for a failed manage-billing fetch. Surfaces the Worker's
    /// own message when it provided one; otherwise a neutral retry line. Never
    /// makes privacy/retention claims.
    static func manageBillingErrorMessage(for error: Error) -> String {
        switch error {
        case LLMError.managedManageBillingUnavailable(let message):
            return message
        case LLMError.managedNotSignedIn:
            return "Sign in to Sentwise AI to manage billing."
        case LLMError.transport:
            return "We couldn't reach billing. Check your connection and try again."
        default:
            return "We couldn't open your billing portal just now. Please try again."
        }
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

    private func isCurrentManageBillingOperation(_ generation: UInt64, accountKey: String) -> Bool {
        manageBillingOperationGeneration == generation && managedAccountMatches(accountKey)
    }
}
