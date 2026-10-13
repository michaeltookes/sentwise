import Foundation

/// Paddle sandbox QA lane on `AppState` (item 123): which Paddle config this
/// account's checkout and plan changes use, and whether checkout can start yet.
/// Split from `AppState+Billing` to keep that file within length limits.
extension AppState {

    // MARK: - Paddle lane (item 123)

    /// The Paddle config this account's checkout and plan changes use, or nil
    /// while checkout can't start yet. Nil until the first `/v1/me` response has
    /// loaded (a QA account must not capture the production config in the gap),
    /// and nil when the Worker reports the account's sandbox lane unavailable.
    /// Otherwise the sandbox only for a `@prowlqa.dev` account the Worker put in
    /// the sandbox lane, production for everyone else (including older Workers
    /// whose `/v1/me` has no `billing` block).
    var checkoutPaddleConfig: PaddleConfig? {
        guard let status = managedAccountStatus else { return nil }
        return PaddleConfig.resolved(billing: status.billing, accountEmail: status.email)
    }

    /// The config for an in-app plan change (item 90 + 123). Plan changes may
    /// start from the persisted subscription snapshot before `/v1/me` loads; that
    /// stays production for ordinary accounts, but a QA (`@prowlqa.dev`) account
    /// waits for `/v1/me` so it never sends a live price to its sandbox lane.
    var planChangePaddleConfig: PaddleConfig? {
        if managedAccountStatus != nil { return checkoutPaddleConfig }
        return PaddleConfig.isQAAccountEmail(managedAccountEmail) ? nil : .active
    }

    /// Whether Subscribe / Upgrade can open checkout right now.
    var canStartCheckout: Bool { checkoutPaddleConfig != nil }

    /// Billing-only caption shown under a disabled Subscribe button, or nil.
    var checkoutUnavailableMessage: String? {
        guard shouldOfferSubscribe, !canStartCheckout else { return nil }
        return managedAccountStatus == nil
            ? "Loading your account…"
            : "Checkout isn't available for this account right now."
    }
}
