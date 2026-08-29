import Foundation

/// The weekly-allotment usage thresholds that fire a native alert (backlog item
/// 56b): 50%, 75%, and 100% of the account's `limit`.
enum UsageAlertThreshold: Int, CaseIterable, Codable, Sendable, Comparable {
    case fifty = 50
    case seventyFive = 75
    case hundred = 100

    static func < (lhs: UsageAlertThreshold, rhs: UsageAlertThreshold) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A ready-to-post usage-threshold notification (title/body/identity). Built by
/// `UsageAlert.make(threshold:quota:)` so `NotificationService` stays decoupled
/// from `ManagedQuota` and just delivers copy.
struct UsageAlert: Equatable, Sendable {
    /// Stable per threshold + weekly window so re-posting replaces rather than
    /// stacks, and a relaunch never double-delivers.
    let identifier: String
    let title: String
    let body: String
    let threshold: UsageAlertThreshold

    /// Builds the alert copy for crossing `threshold`. The 100% copy makes clear
    /// (soft mode) that drafting continues and points to buying extra usage or
    /// switching to an own key; the 50/75% copy is a plain heads-up.
    static func make(threshold: UsageAlertThreshold, quota: ManagedQuota) -> UsageAlert {
        let unit = quota.unit
        let window = ManagedQuotaDate.string(from: quota.resetsAt)
        let identifier = "usage-alert-\(threshold.rawValue)-\(window)"
        let resetPhrase = quota.hasKnownReset
            ? " Your allotment resets \(ManagedQuota.resetDescription(quota.resetsAt))."
            : ""

        switch threshold {
        case .fifty, .seventyFive:
            return UsageAlert(
                identifier: identifier,
                title: "You've used \(threshold.rawValue)% of your weekly \(unit)",
                body: "\(quota.used) of \(quota.limit) \(unit) used this week.\(resetPhrase)",
                threshold: threshold
            )
        case .hundred:
            let body: String
            if quota.enforcement == .hard {
                body = "You've reached your weekly \(unit) allotment. Buy more usage to keep "
                    + "drafting, or switch to your own key for unlimited drafting.\(resetPhrase)"
            } else {
                body = "You've reached your weekly \(unit) allotment. Drafting continues for now — "
                    + "buy more usage or switch to your own key for unlimited drafting.\(resetPhrase)"
            }
            return UsageAlert(
                identifier: identifier,
                title: "You've used all your weekly \(unit)",
                body: body,
                threshold: threshold
            )
        }
    }
}

/// The persisted per-window alert state: which thresholds have already fired for
/// the current weekly window, keyed by the window's `resetsAt`. When `resetsAt`
/// changes (a new window), the fired set is reset so alerts fire again.
struct UsageAlertState: Codable, Equatable, Sendable {
    var windowResetsAt: Date
    var firedThresholds: [Int]

    init(windowResetsAt: Date, firedThresholds: [Int] = []) {
        self.windowResetsAt = windowResetsAt
        self.firedThresholds = firedThresholds
    }
}

/// Pure decision logic for usage alerts (backlog item 56b): given the latest
/// quota and the previously-persisted state, decides which thresholds to fire
/// *now* and the state to persist. Idempotent — a threshold fires once per
/// weekly window; a window change resets the fired set.
enum UsageAlertEvaluator {

    struct Outcome: Equatable {
        /// Thresholds to post a notification for now (ascending).
        let fire: [UsageAlertThreshold]
        /// The state to persist after firing.
        let newState: UsageAlertState
    }

    static func evaluate(quota: ManagedQuota, previous: UsageAlertState?) -> Outcome {
        // A window with no known reset or no limit can't drive stable per-window
        // alerts, so surface nothing and persist nothing meaningful.
        guard quota.hasKnownReset, quota.limit > 0 else {
            return Outcome(fire: [], newState: previous ?? UsageAlertState(windowResetsAt: quota.resetsAt))
        }

        // Reset the fired set when the window rolled over.
        var fired: Set<Int>
        if let previous, previous.windowResetsAt == quota.resetsAt {
            fired = Set(previous.firedThresholds)
        } else {
            fired = []
        }

        let percent = quota.usedPercent
        var toFire: [UsageAlertThreshold] = []
        for threshold in UsageAlertThreshold.allCases where percent >= threshold.rawValue {
            if !fired.contains(threshold.rawValue) {
                fired.insert(threshold.rawValue)
                toFire.append(threshold)
            }
        }

        let newState = UsageAlertState(
            windowResetsAt: quota.resetsAt,
            firedThresholds: fired.sorted()
        )
        return Outcome(fire: toFire.sorted(), newState: newState)
    }
}

/// Persistence seam for the per-window alert state (backlog item 56b). Backed by
/// `UserDefaults` in production; injectable so the idempotence logic is testable
/// without touching disk.
protocol UsageAlertStateStoring: AnyObject, Sendable {
    func loadState() -> UsageAlertState?
    func save(_ state: UsageAlertState)
}

/// `UserDefaults`-backed alert state store. This is ephemeral per-window UI
/// bookkeeping (not the versioned `Settings` schema), so it lives in defaults
/// under a single JSON key rather than forcing a settings migration.
final class UserDefaultsUsageAlertStore: UsageAlertStateStoring, @unchecked Sendable {
    static let defaultsKey = "com.tookes.Sentwise.usageAlertState"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = UserDefaultsUsageAlertStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    func loadState() -> UsageAlertState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(UsageAlertState.self, from: data)
    }

    func save(_ state: UsageAlertState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
