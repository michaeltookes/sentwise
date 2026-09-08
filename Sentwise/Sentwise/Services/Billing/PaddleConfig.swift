import Foundation

/// Which Paddle environment the app talks to. Drives both the Paddle.js
/// `Paddle.Environment.set(...)` call and which credential set is active. Kept
/// separate from the token/price values so a production cutover is a one-line
/// change of `PaddleConfig.active` (backlog item 56c).
enum PaddleEnvironment: String, Sendable, Equatable {
    case sandbox
    case production
}

/// A purchasable paid tier offered at checkout (backlog item 56c). These are the
/// tiers a user can buy from the app; `team` is reserved (seat-based, no client
/// checkout yet) and `trial` / `none` are lifecycle states, not purchases — so
/// they are intentionally absent here. Each case maps to a Paddle price id via
/// `PaddleConfig.priceID(for:)`.
enum PaddlePlan: String, CaseIterable, Identifiable, Sendable, Equatable {
    case starter
    case pro
    case unlimited

    var id: String { rawValue }

    /// The user-facing tier name shown on the plan picker.
    var displayName: String {
        switch self {
        case .starter: return "Starter"
        case .pro: return "Pro"
        case .unlimited: return "Unlimited"
        }
    }

    /// A short, billing-only descriptor for the plan picker. Deliberately says
    /// nothing about privacy/retention — those claims are gated (sentwise items
    /// 56/72) and scoped to the BYO-key/local path only.
    var tagline: String {
        switch self {
        case .starter: return "For getting started with managed drafting"
        case .pro: return "More weekly drafts for daily use"
        case .unlimited: return "The most weekly drafts"
        }
    }

    /// The monthly price shown on the in-app plan cards (item 90). Owner-confirmed
    /// 2026-09-04 and kept in sync with the sentwise.ai pricing page. Billing-only
    /// copy — no privacy/retention claims.
    var monthlyPrice: String {
        switch self {
        case .starter: return "$9"
        case .pro: return "$19"
        case .unlimited: return "$39"
        }
    }

    /// The plan's monthly allowance headline (item 90), matching the marketing
    /// site's owner-confirmed caps. Billing-only copy.
    var allowanceSummary: String {
        switch self {
        case .starter: return "30 follow-ups a month"
        case .pro: return "120 follow-ups a month"
        case .unlimited: return "Unlimited follow-ups"
        }
    }

    /// A one-line qualifier under the allowance headline (item 90). Billing-only.
    var allowanceDetail: String {
        switch self {
        case .starter: return "About one a workday."
        case .pro: return "Room for a full week of calls."
        case .unlimited: return "Fair-use — no cap to watch."
        }
    }

    /// Whether this tier is highlighted as the recommended plan on the cards
    /// (Pro), matching the marketing site's "Most popular" treatment.
    var isFeatured: Bool { self == .pro }

    /// The corresponding subscription plan this purchase results in, for mapping
    /// a completed checkout back to `ManagedSubscription.Plan` in tests/UI.
    var subscriptionPlan: ManagedSubscription.Plan {
        switch self {
        case .starter: return .starter
        case .pro: return .pro
        case .unlimited: return .unlimited
        }
    }

    /// The purchasable tier corresponding to a `ManagedSubscription.Plan`, or nil
    /// for lifecycle/non-purchasable plans (trial / none / team / unknown). Used
    /// to mark the account's current tier on the in-app plan cards (item 90).
    init?(subscriptionPlan: ManagedSubscription.Plan) {
        switch subscriptionPlan {
        case .starter: self = .starter
        case .pro: self = .pro
        case .unlimited: self = .unlimited
        case .trial, .team, .noPlan, .unknown: return nil
        }
    }

    /// Whether moving from `current` to `self` is an upgrade (up the
    /// Starter→Pro→Unlimited ladder) rather than a downgrade. Drives the
    /// Upgrade/Downgrade verb on the plan cards (item 90).
    func isUpgrade(from current: PaddlePlan) -> Bool {
        rank > current.rank
    }

    /// Position on the Starter→Pro→Unlimited ladder (0-based).
    private var rank: Int {
        switch self {
        case .starter: return 0
        case .pro: return 1
        case .unlimited: return 2
        }
    }
}

/// Single source of truth for the Paddle checkout credentials and price ids
/// (backlog item 56c, app half). The sandbox client-side token is public by
/// design (it only permits opening a checkout in frontend code), so embedding it
/// is safe. Production values are swapped by pointing `active` at a
/// `.production` config once the live token and price ids exist — nothing in the
/// UI hardcodes these, so that swap is clean.
struct PaddleConfig: Sendable, Equatable {
    let environment: PaddleEnvironment
    /// Paddle.js client-side token — safe to ship; frontend-scoped by design.
    let clientSideToken: String
    let starterPriceID: String
    let proPriceID: String
    let unlimitedPriceID: String
    /// The origin the bundled checkout page runs under. Paddle overlay checkout
    /// requires the parent page's domain to be an approved domain in the Paddle
    /// dashboard; the WKWebView loads the page with this as its base URL so the
    /// approved-domain check sees a stable, ownable origin (sentwise.ai) rather
    /// than `about:blank`.
    let checkoutOrigin: URL

    /// The Paddle.js `environment` string passed to `Paddle.Environment.set(...)`.
    /// Production is the Paddle default (no call needed), but we set it explicitly
    /// for clarity when the production config is active.
    var paddleJSEnvironment: String { environment.rawValue }

    /// The price id for a purchasable tier.
    func priceID(for plan: PaddlePlan) -> String {
        switch plan {
        case .starter: return starterPriceID
        case .pro: return proPriceID
        case .unlimited: return unlimitedPriceID
        }
    }

    /// The purchasable tier a price id maps to, or nil for an unknown id. Used by
    /// the Prowl-hunt change-plan stub to resolve the requested tier with zero
    /// network (item 90).
    func plan(forPriceID priceID: String) -> PaddlePlan? {
        PaddlePlan.allCases.first { self.priceID(for: $0) == priceID }
    }

    // MARK: - Credential sets

    /// Paddle sandbox credentials (safe to embed). Supplied for 56c so the app
    /// half can be exercised end-to-end against Paddle's sandbox before the
    /// production merchant account is provisioned.
    static let sandbox = PaddleConfig(
        environment: .sandbox,
        clientSideToken: "test_7a55409b65e7f906b94b863e63a",
        starterPriceID: "pri_01m1syd7nfarp8pggpcnvjbgyy",
        proPriceID: "pri_01m1symsxarc4c3jdea0ntb09w",
        unlimitedPriceID: "pri_01m1syrdg05f49kz705gbzn6tz",
        checkoutOrigin: URL(string: "https://sentwise.ai")!
    )

    /// The config the app actually uses. Sandbox until the production merchant
    /// account, live client-side token, and live price ids are provisioned; then
    /// this points at a `.production` config in a single edit.
    static let active: PaddleConfig = sandbox
}
