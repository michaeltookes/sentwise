import CryptoKit
import Foundation

/// Stable, privacy-preserving account key for managed-usage UI state. The raw
/// account identifier is normalized then hashed so UserDefaults and notification
/// identifiers do not store the email address.
enum ManagedUsageAccountKey {
    static let unknown = "acct-unknown"

    static func make(from identifier: String) -> String {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return unknown }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "acct-\(hex)"
    }
}

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
/// `UsageAlert.make(threshold:quota:accountKey:)` so `NotificationService` stays
/// decoupled from `ManagedQuota` and just delivers copy.
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
    static func make(threshold: UsageAlertThreshold, quota: ManagedQuota, accountKey: String) -> UsageAlert {
        let unit = quota.unit
        let window = ManagedQuotaDate.string(from: quota.resetsAt)
        let identifier = "usage-alert-\(accountKey)-\(threshold.rawValue)-\(window)"
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

/// The persisted per-account, per-window alert state: which thresholds have
/// already fired for the signed-in managed account in the current weekly window.
/// When either the account or `resetsAt` changes, the fired set is reset.
struct UsageAlertState: Codable, Equatable, Sendable {
    var accountKey: String
    var windowResetsAt: Date
    var firedThresholds: [Int]

    init(
        accountKey: String = ManagedUsageAccountKey.unknown,
        windowResetsAt: Date,
        firedThresholds: [Int] = []
    ) {
        self.accountKey = accountKey
        self.windowResetsAt = windowResetsAt
        self.firedThresholds = firedThresholds
    }

    private enum CodingKeys: String, CodingKey {
        case accountKey, windowResetsAt, firedThresholds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
            ?? ManagedUsageAccountKey.unknown
        windowResetsAt = try container.decode(Date.self, forKey: .windowResetsAt)
        firedThresholds = try container.decode([Int].self, forKey: .firedThresholds)
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

    static func evaluate(quota: ManagedQuota, previous: UsageAlertState?, accountKey: String) -> Outcome {
        // A window with no known reset or no limit can't drive stable per-window
        // alerts, so surface nothing and persist nothing meaningful.
        guard quota.hasKnownReset, quota.limit > 0 else {
            if let previous, previous.accountKey == accountKey {
                return Outcome(fire: [], newState: previous)
            }
            return Outcome(fire: [], newState: UsageAlertState(accountKey: accountKey, windowResetsAt: quota.resetsAt))
        }

        // Reset the fired set when the account changes or the window rolls over.
        var fired: Set<Int>
        if let previous, previous.accountKey == accountKey, previous.windowResetsAt == quota.resetsAt {
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
            accountKey: accountKey,
            windowResetsAt: quota.resetsAt,
            firedThresholds: fired.sorted()
        )
        return Outcome(fire: toFire.sorted(), newState: newState)
    }
}

/// Persistence seam for the per-account, per-window alert state (backlog item
/// 56b). Backed by `UserDefaults` in production; injectable so the idempotence
/// logic is testable without touching disk.
protocol UsageAlertStateStoring: AnyObject, Sendable {
    func loadState(for accountKey: String) -> UsageAlertState?
    func save(_ state: UsageAlertState)
}

private struct UsageAlertStateCollection: Codable, Equatable, Sendable {
    var statesByAccount: [String: UsageAlertState]
}

/// `UserDefaults`-backed alert state store. This is ephemeral per-window UI
/// bookkeeping (not the versioned `Settings` schema), so it lives in defaults
/// under a single JSON key rather than forcing a settings migration. The JSON
/// value is a map by hashed account key so switching accounts preserves each
/// account's alert history.
final class UserDefaultsUsageAlertStore: UsageAlertStateStoring, @unchecked Sendable {
    static let defaultsKey = "com.tookes.Sentwise.usageAlertState"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = UserDefaultsUsageAlertStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    func loadState(for accountKey: String) -> UsageAlertState? {
        loadStates()[accountKey]
    }

    func save(_ state: UsageAlertState) {
        var states = loadStates()
        states[state.accountKey] = state
        let collection = UsageAlertStateCollection(statesByAccount: states)
        guard let data = try? JSONEncoder().encode(collection) else { return }
        defaults.set(data, forKey: key)
    }

    private func loadStates() -> [String: UsageAlertState] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        if let collection = try? JSONDecoder().decode(UsageAlertStateCollection.self, from: data) {
            return collection.statesByAccount
        }
        if let legacy = try? JSONDecoder().decode(UsageAlertState.self, from: data) {
            return [legacy.accountKey: legacy]
        }
        return [:]
    }
}
