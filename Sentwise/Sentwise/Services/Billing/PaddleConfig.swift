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
        case .pro: return "More monthly drafts for daily use"
        case .unlimited: return "The most monthly drafts"
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

    /// The plan's monthly allowance headline (item 90), matching the enforced
    /// quota window. Billing-only copy.
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
        case .pro: return "Room for a full month of calls."
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

    /// Paddle production credentials (item 74 cutover, 2026-09-20). The
    /// client-side token is frontend-scoped and safe to embed; price ids match
    /// `docs/tier-matrix.md` (Starter $9 / Pro $19 / Unlimited $39, monthly).
    static let production = PaddleConfig(
        environment: .production,
        clientSideToken: "live_3affc7e38f8efd6ebd94616ab39",
        starterPriceID: "pri_01m307sdxtk64vb7yjn4vptrcx",
        proPriceID: "pri_01m307vkn7zf0k194trcmx0qg1",
        unlimitedPriceID: "pri_01m307xfej4zjp0n7wkf4rf9cd",
        checkoutOrigin: URL(string: "https://sentwise.ai")!
    )

    /// The config the app actually uses — production since the item 74 atomic
    /// activation (2026-09-20: approved domain + live webhook confirmed, worker
    /// on the live API base with live tier price vars). Point back at `sandbox`
    /// only for local checkout testing against a sandbox-configured worker.
    static let active: PaddleConfig = production

    // MARK: - Sandbox QA lane (item 123)

    /// QA accounts live on exactly this domain (no subdomains, no look-alikes).
    static let qaAccountEmailDomain = "prowlqa.dev"

    /// Whether `email` is a QA account (exactly `@prowlqa.dev`).
    static func isQAAccountEmail(_ email: String?) -> Bool {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let at = email.firstIndex(of: "@"),
              at != email.startIndex,
              email.lastIndex(of: "@") == at else { return false }
        return email[email.index(after: at)...] == qaAccountEmailDomain
    }

    /// The checkout config for the signed-in account (item 123), or nil when
    /// checkout is unavailable for it.
    ///
    /// - A production account, an older Worker (no `billing`), or any lane other
    ///   than `sandbox` gets the production config, so a production account can
    ///   never see sandbox prices.
    /// - A QA (`@prowlqa.dev`) account the Worker put in the sandbox lane gets a
    ///   sandbox config only when the Worker says checkout is available and
    ///   supplied a `test_…` token plus three distinct, non-live price ids.
    ///   Otherwise nil: the Worker routes that account's checkout to the sandbox,
    ///   so falling back to live prices would only produce a server rejection.
    static func resolved(billing: ManagedBillingLane?, accountEmail: String?) -> PaddleConfig? {
        guard let billing,
              billing.environment == PaddleEnvironment.sandbox.rawValue,
              isQAAccountEmail(accountEmail) else {
            return active
        }
        guard billing.checkoutAvailable != false,
              let token = nonEmpty(billing.clientSideToken),
              token.hasPrefix("test_"),
              let prices = billing.prices,
              let starter = nonEmpty(prices.starter),
              let pro = nonEmpty(prices.pro),
              let unlimited = nonEmpty(prices.unlimited),
              Set([starter, pro, unlimited]).count == 3,
              Set([starter, pro, unlimited]).isDisjoint(with: productionPriceIDs) else {
            return nil
        }
        return PaddleConfig(
            environment: .sandbox,
            clientSideToken: token,
            starterPriceID: starter,
            proPriceID: pro,
            unlimitedPriceID: unlimited,
            checkoutOrigin: active.checkoutOrigin
        )
    }

    private static var productionPriceIDs: Set<String> {
        Set(PaddlePlan.allCases.map { production.priceID(for: $0) })
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
