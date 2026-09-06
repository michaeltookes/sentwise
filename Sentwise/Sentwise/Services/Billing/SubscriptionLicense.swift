import Foundation

/// A durable snapshot of the last-known subscription from `GET /v1/me` (backlog
/// item 56c). The "license" for managed drafting is the subscription status, so
/// caching the last-known status lets the app keep functioning within a grace
/// window when `/v1/me` is unreachable (offline, or a transient server error)
/// rather than bricking the UI. Reuses the same lenient-Codable stance as
/// `ManagedSubscription`: unknown raw values decode to `.unknown` and never throw.
struct SubscriptionSnapshot: Codable, Equatable, Sendable {
    let plan: ManagedSubscription.Plan
    let status: ManagedSubscription.Status
    let renewsAt: Date?
    let manageBillingURL: String?
    /// When this snapshot was captured locally (the successful `/v1/me` fetch).
    let capturedAt: Date

    init(
        plan: ManagedSubscription.Plan,
        status: ManagedSubscription.Status,
        renewsAt: Date? = nil,
        manageBillingURL: String? = nil,
        capturedAt: Date
    ) {
        self.plan = plan
        self.status = status
        self.renewsAt = renewsAt
        self.manageBillingURL = manageBillingURL
        self.capturedAt = capturedAt
    }

    /// Captures a snapshot from a live subscription. Returns nil when there is no
    /// subscription block to cache.
    init?(subscription: ManagedSubscription?, capturedAt: Date = Date()) {
        guard let subscription else { return nil }
        self.init(
            plan: subscription.plan,
            status: subscription.status,
            renewsAt: subscription.renewsAt,
            manageBillingURL: subscription.manageBillingURL,
            capturedAt: capturedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case plan, status, renewsAt, manageBillingURL, capturedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let planRaw = (try? container.decode(String.self, forKey: .plan)) ?? ""
        plan = ManagedSubscription.Plan(rawValue: planRaw) ?? .unknown
        let statusRaw = (try? container.decode(String.self, forKey: .status)) ?? ""
        status = ManagedSubscription.Status(rawValue: statusRaw) ?? .unknown
        renewsAt = try container.decodeIfPresent(Date.self, forKey: .renewsAt)
        manageBillingURL = try container.decodeIfPresent(String.self, forKey: .manageBillingURL)
        capturedAt = (try? container.decode(Date.self, forKey: .capturedAt)) ?? .distantPast
    }
}

/// The evaluated entitlement for managed drafting, derived from the live status
/// when online or the cached snapshot within a grace window when offline.
enum SubscriptionLicense: Equatable, Sendable {
    /// Entitled to managed drafting (trialing or active).
    case entitled
    /// Not currently entitled per the last-known status (past_due / canceled /
    /// lapsed / none), but the app UI still functions.
    case notEntitled
    /// Offline/unknown live status, but a cached entitled snapshot is still within
    /// the grace window — keep functioning. `daysRemaining` is whole days of grace
    /// left, rounded up.
    case grace(daysRemaining: Int)
    /// No usable information (never signed in, or cache expired past grace).
    case unknown
}

/// Pure entitlement logic (backlog item 56c). Deterministic — `now` is injected —
/// so the offline-grace behavior is unit-testable without any clock or network.
enum SubscriptionLicenseEvaluator {

    /// Default offline grace: keep functioning on the last-known entitlement for
    /// this long after the last successful `/v1/me` before falling back to
    /// `.unknown`. Chosen to comfortably outlast a typical network outage or a
    /// weekend without a paid feature silently disappearing.
    static let defaultGrace: TimeInterval = 7 * 24 * 60 * 60

    /// Whether a status entitles managed drafting.
    static func isEntitled(_ status: ManagedSubscription.Status) -> Bool {
        switch status {
        case .trialing, .active: return true
        case .pastDue, .canceled, .lapsed, .unknown: return false
        }
    }

    /// Evaluates entitlement. When `liveStatus` is known, it wins directly. When
    /// it is nil (offline or `/v1/me` failed), fall back to the cached snapshot:
    /// an entitled snapshot within `grace` yields `.grace`, an entitled snapshot
    /// past grace yields `.unknown`, and a not-entitled snapshot yields
    /// `.notEntitled` (a lapse we already knew about doesn't get re-graced).
    static func evaluate(
        liveStatus: ManagedSubscription.Status?,
        cached: SubscriptionSnapshot?,
        now: Date = Date(),
        grace: TimeInterval = defaultGrace
    ) -> SubscriptionLicense {
        if let liveStatus, liveStatus != .unknown {
            return isEntitled(liveStatus) ? .entitled : .notEntitled
        }

        guard let cached else { return .unknown }

        guard isEntitled(cached.status) else {
            // We already knew the account wasn't entitled; no grace to extend.
            return cached.status == .unknown ? .unknown : .notEntitled
        }

        let elapsed = now.timeIntervalSince(cached.capturedAt)
        if elapsed <= 0 {
            return .grace(daysRemaining: graceDays(grace))
        }
        if elapsed >= grace {
            return .unknown
        }
        return .grace(daysRemaining: graceDays(grace - elapsed))
    }

    private static func graceDays(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 86_400).rounded(.up)))
    }
}

/// Durable store for the last-known subscription snapshot (backlog item 56c),
/// keyed by a hashed account key so a second account on the same Mac doesn't read
/// the first account's entitlement. Behind a protocol so the offline-grace
/// behavior is unit-testable with an in-memory double. Mirrors the light
/// `UserDefaults` persistence used by `UserDefaultsGoogleOAuthInterestStore`.
protocol SubscriptionCacheStoring: AnyObject, Sendable {
    func snapshot(accountKey: String) -> SubscriptionSnapshot?
    func save(_ snapshot: SubscriptionSnapshot, accountKey: String)
    func clear(accountKey: String)
}

/// A `UserDefaults`-backed subscription cache. Stores a small JSON blob per
/// account key.
final class UserDefaultsSubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
    static let defaultsKeyPrefix = "subscriptionSnapshot."

    private let defaults: UserDefaults
    private let prefix: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, prefix: String = UserDefaultsSubscriptionCacheStore.defaultsKeyPrefix) {
        self.defaults = defaults
        self.prefix = prefix
    }

    func snapshot(accountKey: String) -> SubscriptionSnapshot? {
        guard let data = defaults.data(forKey: key(accountKey)) else { return nil }
        return try? decoder.decode(SubscriptionSnapshot.self, from: data)
    }

    func save(_ snapshot: SubscriptionSnapshot, accountKey: String) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: key(accountKey))
    }

    func clear(accountKey: String) {
        defaults.removeObject(forKey: key(accountKey))
    }

    private func key(_ accountKey: String) -> String { prefix + accountKey }
}
