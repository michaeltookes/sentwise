import SentwiseMail
import Foundation

/// A bounded, ordered record of inbox messages the watcher has already handled,
/// so the same message is never drafted twice — even across app restarts.
///
/// Each message is identified by its RFC 5322 `Message-ID` when available,
/// scoped to the current account and mailbox, falling back to `UIDVALIDITY:UID`
/// (stable within a mailbox). Oldest keys are evicted first once `limit` is
/// exceeded, so the store stays small while still covering any realistic poll
/// window.
struct ProcessedMessages: Codable, Equatable {

    struct BaselineUIDCutoff: Codable, Equatable {
        var uid: UInt32
        var uidValidity: UInt32?
    }

    /// Maximum number of remembered keys before the oldest are evicted.
    static let limit = 1000

    /// Remembered message keys, oldest first.
    private(set) var keys: [String]
    /// Account/mailbox scopes that have had their initial watcher baseline seeded.
    private(set) var baselines: [String]
    /// Account/mailbox scopes and local start cutoffs for watcher drafting.
    private(set) var baselineStarts: [String: Date]
    /// Account/mailbox UID cutoffs captured at the watcher baseline boundary.
    private(set) var baselineUIDs: [String: BaselineUIDCutoff]

    init(
        keys: [String] = [],
        baselines: [String] = [],
        baselineStarts: [String: Date] = [:],
        baselineUIDs: [String: BaselineUIDCutoff] = [:]
    ) {
        self.keys = keys
        self.baselines = baselines
        self.baselineStarts = baselineStarts
        self.baselineUIDs = baselineUIDs
    }

    enum CodingKeys: String, CodingKey {
        case keys
        case baselines
        case baselineStarts
        case baselineUIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decodeIfPresent([String].self, forKey: .keys) ?? []
        baselines = try container.decodeIfPresent([String].self, forKey: .baselines) ?? []
        baselineStarts = try container.decodeIfPresent([String: Date].self, forKey: .baselineStarts) ?? [:]
        do {
            baselineUIDs = try container.decodeIfPresent([String: BaselineUIDCutoff].self, forKey: .baselineUIDs) ?? [:]
        } catch {
            let legacyUIDs = try container.decodeIfPresent([String: UInt32].self, forKey: .baselineUIDs) ?? [:]
            baselineUIDs = legacyUIDs.mapValues { BaselineUIDCutoff(uid: $0, uidValidity: nil) }
        }
    }

    /// Whether `message` has already been processed.
    func contains(_ message: MailMessage, account: String, mailbox: Mailbox) -> Bool {
        let messageKeys = Self.keys(for: message, account: account, mailbox: mailbox)
        return keys.contains { messageKeys.contains($0) }
    }

    /// Records `message` as processed, evicting the oldest keys past `limit`.
    /// No-op if already present (its position is left unchanged).
    mutating func insert(_ message: MailMessage, account: String, mailbox: Mailbox) {
        guard !contains(message, account: account, mailbox: mailbox) else { return }
        let key = Self.key(for: message, account: account, mailbox: mailbox)
        keys.append(key)
        if keys.count > Self.limit {
            keys.removeFirst(keys.count - Self.limit)
        }
    }

    /// Whether the watcher has seeded the current-inbox baseline for this scope.
    func hasBaseline(account: String, mailbox: Mailbox) -> Bool {
        baselines.contains(Self.baselineKey(account: account, mailbox: mailbox))
    }

    /// Records that the watcher has seeded the current-inbox baseline for this scope.
    mutating func insertBaseline(account: String, mailbox: Mailbox) {
        let key = Self.baselineKey(account: account, mailbox: mailbox)
        guard !baselines.contains(key) else { return }
        baselines.append(key)
    }

    /// Records when initial baseline capture began for this watcher scope.
    mutating func setBaselineStart(account: String, mailbox: Mailbox, date: Date) {
        baselineStarts[Self.baselineKey(account: account, mailbox: mailbox)] = date
    }

    /// Whether the watcher has started initial baseline capture for this scope.
    func hasBaselineStart(account: String, mailbox: Mailbox) -> Bool {
        baselineStartDate(account: account, mailbox: mailbox) != nil
    }

    /// The local time when initial baseline capture began for this scope, if any.
    func baselineStartDate(account: String, mailbox: Mailbox) -> Date? {
        baselineStarts[Self.baselineKey(account: account, mailbox: mailbox)]
    }

    /// Records the newest UID that belongs to the historical watcher baseline.
    mutating func setBaselineUID(account: String, mailbox: Mailbox, uid: UInt32, uidValidity: UInt32?) {
        baselineUIDs[Self.baselineKey(account: account, mailbox: mailbox)] = BaselineUIDCutoff(
            uid: uid,
            uidValidity: uidValidity
        )
    }

    /// The newest UID that belongs to the historical watcher baseline, if known.
    func baselineUID(account: String, mailbox: Mailbox) -> BaselineUIDCutoff? {
        baselineUIDs[Self.baselineKey(account: account, mailbox: mailbox)]
    }

    /// Removes all processed-message and watcher-baseline records for `account`,
    /// preserving other saved accounts' dedup state.
    mutating func removeAccount(_ account: String) {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !account.isEmpty else { return }
        let scopePrefix = "acct=\(account)|"
        keys.removeAll { $0.hasPrefix("mid:\(scopePrefix)") || $0.hasPrefix("uid:\(scopePrefix)") }
        baselines.removeAll { $0.hasPrefix("baseline:\(scopePrefix)") }
        baselineStarts = baselineStarts.filter { !$0.key.hasPrefix("baseline:\(scopePrefix)") }
        baselineUIDs = baselineUIDs.filter { !$0.key.hasPrefix("baseline:\(scopePrefix)") }
    }

    /// Clears the watcher baseline (seed marker, start date, and UID cutoff) for
    /// one account/mailbox scope, without touching processed-message dedup keys
    /// (item 108). Used to re-baseline on managed sign-in/reauth so the resumed
    /// watcher treats "now" as the new start and drops the accumulated backlog
    /// instead of replaying it.
    mutating func resetBaseline(account: String, mailbox: Mailbox) {
        let key = Self.baselineKey(account: account, mailbox: mailbox)
        baselines.removeAll { $0 == key }
        baselineStarts.removeValue(forKey: key)
        baselineUIDs.removeValue(forKey: key)
    }

    /// A stable identity for a message: its Message-ID when present, else a
    /// scoped `UIDVALIDITY:UID` composite (stable within one account/mailbox).
    static func key(for message: MailMessage, account: String, mailbox: Mailbox) -> String {
        if let messageID = message.messageID, !messageID.isEmpty {
            return "mid:\(scopeKey(account: account, mailbox: mailbox))|messageID=\(messageID)"
        }
        return fallbackKey(for: message, account: account, mailbox: mailbox)
    }

    private static func keys(for message: MailMessage, account: String, mailbox: Mailbox) -> Set<String> {
        var keys = Set([key(for: message, account: account, mailbox: mailbox)])
        keys.insert(fallbackKey(for: message, account: account, mailbox: mailbox))
        return keys
    }

    private static func fallbackKey(for message: MailMessage, account: String, mailbox: Mailbox) -> String {
        let validity = message.uidValidity.map(String.init) ?? "?"
        return "uid:\(scopeKey(account: account, mailbox: mailbox))|validity=\(validity)|uid=\(message.id)"
    }

    static func baselineKey(account: String, mailbox: Mailbox) -> String {
        "baseline:\(scopeKey(account: account, mailbox: mailbox))"
    }

    private static func scopeKey(account: String, mailbox: Mailbox) -> String {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mailbox = mailbox.imapName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "acct=\(account)|mailbox=\(mailbox)"
    }
}
