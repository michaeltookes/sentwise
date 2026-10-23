import Foundation

/// Which Paddle environment the app talks to. Drives the Paddle.js
/// `Paddle.Environment.set(...)` call. Production builds always use
/// `.production`; only a QA build's Info.plist can select `.sandbox`
/// (`BuildConfiguration`, item 123).
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
/// (backlog item 56c, app half). Client-side tokens are public by design (they
/// only permit opening a checkout in frontend code), so embedding the live one
/// is safe. Production builds embed only the live values; a QA build's sandbox
/// values come from its Info.plist (`BuildConfiguration`, item 123), so no
/// sandbox credential ships in the production app.
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

    /// Canonical launch values verified against the live $9 / $19 / $39 monthly
    /// catalog. Keeping the expected price mapping separate from the assembled
    /// config lets the release resolver reject an accidental blank, duplicate,
    /// sandbox, or tier-swapped value instead of opening the wrong checkout.
    private enum ProductionValues {
        static let clientSideToken = "live_3affc7e38f8efd6ebd94616ab39"
        static let starterPriceID = "pri_01m307sdxtk64vb7yjn4vptrcx"
        static let proPriceID = "pri_01m307vkn7zf0k194trcmx0qg1"
        static let unlimitedPriceID = "pri_01m307xfej4zjp0n7wkf4rf9cd"
        static let checkoutOrigin = URL(string: "https://sentwise.ai")!
    }

    /// Paddle production credentials (item 74 cutover, 2026-09-20). The
    /// client-side token is frontend-scoped and safe to embed; price ids match
    /// `docs/tier-matrix.md` (Starter $9 / Pro $19 / Unlimited $39, monthly).
    static let production = PaddleConfig(
        environment: .production,
        clientSideToken: ProductionValues.clientSideToken,
        starterPriceID: ProductionValues.starterPriceID,
        proPriceID: ProductionValues.proPriceID,
        unlimitedPriceID: ProductionValues.unlimitedPriceID,
        checkoutOrigin: ProductionValues.checkoutOrigin
    )

    /// Returns a field-only diagnostic when a release candidate's embedded
    /// Paddle values do not exactly match the approved production catalog.
    /// Values are deliberately omitted so logs never disclose credentials.
    static func productionValidationProblem(for config: PaddleConfig) -> String? {
        guard config.environment == .production else { return "Paddle environment is not production" }
        guard config.clientSideToken.range(of: #"^live_[A-Za-z0-9]+$"#, options: .regularExpression) != nil else {
            return "Paddle client token is blank, malformed, or not live"
        }
        let actualIDs = PaddlePlan.allCases.map { config.priceID(for: $0) }
        guard actualIDs.allSatisfy({ !$0.isEmpty }) else { return "a Paddle price id is blank" }
        guard Set(actualIDs).count == actualIDs.count else { return "Paddle price ids are not distinct" }
        let expectedIDs = PaddlePlan.allCases.map { production.priceID(for: $0) }
        guard actualIDs == expectedIDs else { return "Paddle price ids do not match the approved tier mapping" }
        guard config.clientSideToken == ProductionValues.clientSideToken else {
            return "Paddle client token does not match the approved live configuration"
        }
        guard config.checkoutOrigin == ProductionValues.checkoutOrigin else {
            return "Paddle checkout origin does not match the approved production domain"
        }
        return nil
    }

    /// The config this build uses: `production` for Debug/Release builds, the
    /// sandbox values from Info.plist for a QA build, or nil when a QA build's
    /// Paddle values are incomplete or inconsistent — checkout is then
    /// unavailable rather than falling back to production prices (item 123).
    static let active: PaddleConfig? = BuildConfiguration.current.paddle
}
