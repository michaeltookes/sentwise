import Foundation

/// How many mailboxes a subscription tier may connect concurrently (item 99,
/// gated by `docs/tier-matrix.md`). The committed caps are Starter 1, Pro 2,
/// Unlimited up to 5, and Trial 2 (Pro-equivalent). Enforcement is client-side,
/// keyed off `subscription.plan` from `/v1/me` (the accepted A-L5-style posture:
/// a source-builder can bypass a client gate — open core accepts this).
enum AccountConnectionLimit {

    /// The default cap when the plan is unknown (never fetched, or a plan value a
    /// newer server introduced). Chosen lenient (trial/Pro-equivalent) so a
    /// transient unknown never wrongly blocks a legitimate multi-account user; the
    /// cached `/v1/me` snapshot supplies the real plan when offline.
    static let defaultLimit = 2

    /// The maximum number of concurrently connected mailboxes for `plan`.
    static func maxConnectedAccounts(for plan: ManagedSubscription.Plan?) -> Int {
        switch plan {
        case .starter:
            return 1
        case .pro, .trial:
            return 2
        case .unlimited:
            return 5
        // `team` is reserved (not sold); treat as Pro-equivalent until a seat model
        // ships. `none`/`unknown`/nil fall back to the lenient default.
        case .team:
            return 2
        case .noPlan, .unknown, .none:
            return defaultLimit
        }
    }
}
