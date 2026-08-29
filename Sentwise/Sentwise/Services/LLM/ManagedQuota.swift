import Foundation

/// The account's current usage allotment as reported by the `sentwise-service`
/// Worker (backlog item 56b). Present on both `GET /v1/me` and every
/// `POST /v1/draft` response; treated as optional when decoding because older
/// Worker builds omit it entirely.
///
/// Tokens are metered under the hood for true cost/margin, but the UI presents a
/// friendly unit (`drafts`). Enforcement is `soft` while dogfooding — drafting is
/// never blocked; the hard-block and real "buy more" arrive with 56c.
struct ManagedQuota: Codable, Sendable, Equatable {

    /// Whether the weekly allotment is enforced. `soft` warns but never blocks;
    /// `hard` blocks over-limit drafting server-side (56c).
    enum Enforcement: String, Codable, Sendable, Equatable {
        case soft
        case hard
    }

    /// The user-facing unit the counters are expressed in (e.g. "drafts").
    var unit: String
    /// Drafts consumed in the current weekly window.
    var used: Int
    /// The weekly allotment (server-configurable — may change without an app release).
    var limit: Int
    /// Drafts remaining in the current window (server-computed).
    var remaining: Int
    /// When the current weekly window resets (Monday 00:00 UTC by default).
    var resetsAt: Date
    /// Tokens consumed under the hood — surfaced for the margin dashboard, not the UI.
    var tokensUsed: Int
    /// The token cap under the hood.
    var tokenLimit: Int
    /// Whether over-limit drafting is blocked (`hard`) or only warned (`soft`).
    var enforcement: Enforcement
    /// Additional usage the user has purchased this billing period (56c). `0`
    /// until the purchase flow ships.
    var extraPurchased: Int

    init(
        unit: String = "drafts",
        used: Int = 0,
        limit: Int = 0,
        remaining: Int = 0,
        resetsAt: Date,
        tokensUsed: Int = 0,
        tokenLimit: Int = 0,
        enforcement: Enforcement = .soft,
        extraPurchased: Int = 0
    ) {
        self.unit = unit
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.tokensUsed = tokensUsed
        self.tokenLimit = tokenLimit
        self.enforcement = enforcement
        self.extraPurchased = extraPurchased
    }

    private enum CodingKeys: String, CodingKey {
        case unit, used, limit, remaining, resetsAt, tokensUsed, tokenLimit, enforcement, extraPurchased
    }

    /// Lenient decoding: tolerates missing numeric fields (default 0), an unknown
    /// or missing `enforcement` (defaults to the non-blocking `soft`), and an
    /// `resetsAt` that is either present as an ISO-8601 string or absent (defaults
    /// to `.distantPast`, which the display layer treats as "unknown reset").
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unit = (try? container.decode(String.self, forKey: .unit)) ?? "drafts"
        used = (try? container.decode(Int.self, forKey: .used)) ?? 0
        limit = (try? container.decode(Int.self, forKey: .limit)) ?? 0
        tokensUsed = (try? container.decode(Int.self, forKey: .tokensUsed)) ?? 0
        tokenLimit = (try? container.decode(Int.self, forKey: .tokenLimit)) ?? 0
        extraPurchased = (try? container.decode(Int.self, forKey: .extraPurchased)) ?? 0

        // `remaining` is server-computed; fall back to limit − used when absent.
        if let decodedRemaining = try? container.decode(Int.self, forKey: .remaining) {
            remaining = decodedRemaining
        } else {
            remaining = max(0, limit - used)
        }

        if let rawEnforcement = try? container.decode(String.self, forKey: .enforcement),
           let parsed = Enforcement(rawValue: rawEnforcement) {
            enforcement = parsed
        } else {
            enforcement = .soft
        }

        if let iso = try? container.decode(String.self, forKey: .resetsAt),
           let date = ManagedQuotaDate.date(from: iso) {
            resetsAt = date
        } else {
            resetsAt = .distantPast
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(unit, forKey: .unit)
        try container.encode(used, forKey: .used)
        try container.encode(limit, forKey: .limit)
        try container.encode(remaining, forKey: .remaining)
        try container.encode(ManagedQuotaDate.string(from: resetsAt), forKey: .resetsAt)
        try container.encode(tokensUsed, forKey: .tokensUsed)
        try container.encode(tokenLimit, forKey: .tokenLimit)
        try container.encode(enforcement, forKey: .enforcement)
        try container.encode(extraPurchased, forKey: .extraPurchased)
    }

    // MARK: - Derived values

    /// Fraction of the weekly allotment consumed, clamped to `0...1`. `0` when the
    /// limit is unknown (so a `ProgressView` renders empty rather than crashing).
    var usedFraction: Double {
        guard limit > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(limit)))
    }

    /// Integer percent of the allotment consumed (uncapped, so the 100%+ threshold
    /// logic can see an over-limit account). `0` when the limit is unknown.
    var usedPercent: Int {
        guard limit > 0 else { return 0 }
        return Int((Double(used) / Double(limit) * 100).rounded(.down))
    }

    /// Whether a real reset time is known (vs. the `.distantPast` sentinel used
    /// when the Worker omitted `resetsAt`).
    var hasKnownReset: Bool { resetsAt > .distantPast }

    // MARK: - Display

    /// The main usage line for the Settings pane, e.g.
    /// "12 of 50 drafts used this week · resets Monday, 5:00 PM".
    func usageSummary(calendar: Calendar = .current, locale: Locale = .current) -> String {
        let base = "\(used) of \(limit) \(unit) used this week"
        guard hasKnownReset else { return base }
        return "\(base) · resets \(Self.resetDescription(resetsAt, calendar: calendar, locale: locale))"
    }

    /// A weekday + time description of a reset instant in the user's locale,
    /// e.g. "Monday, 5:00 PM".
    static func resetDescription(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE h mm a")
        return formatter.string(from: date)
    }
}

/// Shared ISO-8601 parsing for `resetsAt`, tolerating an optional fractional
/// seconds component (the Worker may or may not include milliseconds).
enum ManagedQuotaDate {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }

    static func string(from date: Date) -> String {
        plain.string(from: date)
    }
}
