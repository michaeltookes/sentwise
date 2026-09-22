import Foundation

/// Per-account, per-window bookkeeping for the monthly auto-draft budget cap
/// (item 108). Counts only auto-generated inbox drafts in the current managed
/// allotment window; manual on-demand and transcript follow-ups never touch it.
/// When either the account or the window (`windowResetsAt`) changes, the counter
/// resets. `capAlertFired` makes the "auto-drafting paused for this month" alert
/// fire once per window rather than on every capped message.
struct AutoDraftBudgetState: Codable, Equatable, Sendable {
    var accountKey: String
    var windowResetsAt: Date
    var used: Int
    var capAlertFired: Bool

    init(
        accountKey: String = ManagedUsageAccountKey.unknown,
        windowResetsAt: Date,
        used: Int = 0,
        capAlertFired: Bool = false
    ) {
        self.accountKey = accountKey
        self.windowResetsAt = windowResetsAt
        self.used = used
        self.capAlertFired = capAlertFired
    }

    private enum CodingKeys: String, CodingKey {
        case accountKey, windowResetsAt, used, capAlertFired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
            ?? ManagedUsageAccountKey.unknown
        windowResetsAt = try container.decode(Date.self, forKey: .windowResetsAt)
        used = try container.decodeIfPresent(Int.self, forKey: .used) ?? 0
        capAlertFired = try container.decodeIfPresent(Bool.self, forKey: .capAlertFired) ?? false
    }
}

/// Persistence seam for the auto-draft budget counter (item 108). Backed by
/// `UserDefaults` in production; injectable so the cap logic is testable without
/// touching disk. This is ephemeral per-window bookkeeping (like the usage-alert
/// store), not the versioned `Settings` schema.
protocol AutoDraftBudgetStoring: AnyObject, Sendable {
    func loadState(for accountKey: String) -> AutoDraftBudgetState?
    func save(_ state: AutoDraftBudgetState)
    func removeState(for accountKey: String)
    func clearAll()
}

extension AutoDraftBudgetStoring {
    /// Preserves auto-draft budget usage when an upgraded signed-in account moves
    /// from a legacy session-scoped key to its stable Clerk-user key.
    func migrateState(from oldAccountKey: String, to newAccountKey: String) {
        guard oldAccountKey != newAccountKey,
              var oldState = loadState(for: oldAccountKey)
        else { return }

        oldState.accountKey = newAccountKey
        guard var existing = loadState(for: newAccountKey) else {
            save(oldState)
            removeState(for: oldAccountKey)
            return
        }

        if existing.windowResetsAt == oldState.windowResetsAt {
            existing.used += oldState.used
            existing.capAlertFired = existing.capAlertFired || oldState.capAlertFired
            save(existing)
        } else if oldState.windowResetsAt > existing.windowResetsAt {
            save(oldState)
        }
        removeState(for: oldAccountKey)
    }

    func removeState(for _: String) {}
    func clearAll() {}
}

private struct AutoDraftBudgetStateCollection: Codable, Equatable, Sendable {
    var statesByAccount: [String: AutoDraftBudgetState]
}

/// `UserDefaults`-backed auto-draft budget store, keyed by hashed account so
/// switching accounts preserves each account's counter.
final class UserDefaultsAutoDraftBudgetStore: AutoDraftBudgetStoring, @unchecked Sendable {
    static let defaultsKey = "com.tookes.Sentwise.autoDraftBudgetState"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = UserDefaultsAutoDraftBudgetStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    func loadState(for accountKey: String) -> AutoDraftBudgetState? {
        loadStates()[accountKey]
    }

    func save(_ state: AutoDraftBudgetState) {
        var states = loadStates()
        states[state.accountKey] = state
        let collection = AutoDraftBudgetStateCollection(statesByAccount: states)
        guard let data = try? JSONEncoder().encode(collection) else { return }
        defaults.set(data, forKey: key)
    }

    func removeState(for accountKey: String) {
        var states = loadStates()
        states.removeValue(forKey: accountKey)
        let collection = AutoDraftBudgetStateCollection(statesByAccount: states)
        guard let data = try? JSONEncoder().encode(collection) else { return }
        defaults.set(data, forKey: key)
    }

    func clearAll() {
        defaults.removeObject(forKey: key)
    }

    private func loadStates() -> [String: AutoDraftBudgetState] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        if let collection = try? JSONDecoder().decode(AutoDraftBudgetStateCollection.self, from: data) {
            return collection.statesByAccount
        }
        return [:]
    }
}
