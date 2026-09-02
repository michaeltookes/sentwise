import Foundation

/// The time window a `DraftFeedbackStats` aggregate covers (item 84). Windows are
/// "since a cutoff", measured as a fixed number of days back from `now`; `allTime`
/// has no cutoff. Interval math (not calendar-day boundaries) keeps the buckets
/// deterministic and test-stable.
enum DraftFeedbackWindow: String, CaseIterable, Identifiable {
    case last7Days
    case last30Days
    case allTime

    var id: String { rawValue }

    /// The user-facing label for the window's column/section header.
    var displayTitle: String {
        switch self {
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        case .allTime: return "All time"
        }
    }

    /// Days back from `now` this window includes, or `nil` for `allTime`.
    var days: Int? {
        switch self {
        case .last7Days: return 7
        case .last30Days: return 30
        case .allTime: return nil
        }
    }
}

/// A pure, on-device aggregate of `DraftFeedbackRecord`s for one window (item 84,
/// derived from the item-83 Phase-1 store). Everything here is computed locally
/// from codes/numbers/hashes; no free text (the deny "Other" text) is read, and
/// nothing leaves the machine.
///
/// **Rate denominator (load-bearing):** the three headline rates are fractions of
/// *decided* drafts — approved-as-is + approved-after-edit + denied. A manually
/// abandoned preview (`.abandoned`) is a dismissed preview, not a verdict on draft
/// quality, so it is excluded from the rate denominators (its count is still
/// exposed as `abandonedCount`). This keeps the three rates summing to ~1.
struct DraftFeedbackWindowStats: Equatable {
    /// Approved without editing the generated body.
    var approvedAsIsCount: Int
    /// Approved after editing the body.
    var approvedAfterEditCount: Int
    /// Denied from the review queue.
    var deniedCount: Int
    /// Manual previews dismissed without approval (excluded from rate denominators).
    var abandonedCount: Int

    /// Approved-as-is + approved-after-edit + denied — the denominator for the
    /// three rates below.
    var decidedCount: Int { approvedAsIsCount + approvedAfterEditCount + deniedCount }

    /// One-shot-accept rate: approved-as-is ÷ decided. `0` when nothing decided.
    var oneShotAcceptRate: Double { rate(approvedAsIsCount) }
    /// Edited rate: approved-after-edit ÷ decided. `0` when nothing decided.
    var editedRate: Double { rate(approvedAfterEditCount) }
    /// Denied rate: denied ÷ decided. `0` when nothing decided.
    var deniedRate: Double { rate(deniedCount) }

    /// Mean normalized edit magnitude over edited approvals that carry one, or
    /// `nil` when there were no such records in the window.
    var averageEditMagnitude: Double?

    /// Counts of denials by reason code, over denied records that carry a reason.
    /// Legacy/direct denials with no reason are counted in `deniedCount` but not
    /// here. Every `DenyReasonCode` key is present (0 when unused) so the display
    /// and hunts see a stable set of rows.
    var denyReasonCounts: [DenyReasonCode: Int]

    /// Approvals (as-is or after-edit) where the user first answered a
    /// `NEEDS_INFO` prompt (item 85's `answeredNeedsInfo`) — the
    /// "answered-then-approved" signal.
    var answeredThenApprovedCount: Int

    private func rate(_ numerator: Int) -> Double {
        let denominator = decidedCount
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }
}

/// Pure aggregator over the item-83 feedback store (item 84). No SwiftUI, no
/// `Date()` capture inside the math — `now` is injected so windowing is
/// deterministic under test and in Prowl hunt mode.
enum DraftFeedbackStats {

    /// Total records in the store — drives the window's `< 3` empty state.
    static func totalRecordCount(_ records: [DraftFeedbackRecord]) -> Int {
        records.count
    }

    /// Computes the aggregate for one window. Records are filtered to those whose
    /// `timestamp` is at or after the window's cutoff (`allTime` keeps everything).
    static func compute(
        records: [DraftFeedbackRecord],
        window: DraftFeedbackWindow,
        now: Date = Date()
    ) -> DraftFeedbackWindowStats {
        let scoped = inWindow(records, window: window, now: now)

        var asIs = 0, afterEdit = 0, denied = 0, abandoned = 0
        var magnitudeSum = 0.0
        var magnitudeCount = 0
        var reasonCounts: [DenyReasonCode: Int] = Dictionary(
            uniqueKeysWithValues: DenyReasonCode.allCases.map { ($0, 0) }
        )
        var answeredApproved = 0

        for record in scoped {
            switch record.outcome {
            case .approvedAsIs:
                asIs += 1
                if record.answeredNeedsInfo { answeredApproved += 1 }
            case .approvedAfterEdit:
                afterEdit += 1
                if record.answeredNeedsInfo { answeredApproved += 1 }
                if let magnitude = record.editMagnitude {
                    magnitudeSum += magnitude
                    magnitudeCount += 1
                }
            case .denied:
                denied += 1
                if let code = record.denyReason?.code {
                    reasonCounts[code, default: 0] += 1
                }
            case .abandoned:
                abandoned += 1
            }
        }

        return DraftFeedbackWindowStats(
            approvedAsIsCount: asIs,
            approvedAfterEditCount: afterEdit,
            deniedCount: denied,
            abandonedCount: abandoned,
            averageEditMagnitude: magnitudeCount > 0 ? magnitudeSum / Double(magnitudeCount) : nil,
            denyReasonCounts: reasonCounts,
            answeredThenApprovedCount: answeredApproved
        )
    }

    /// Filters `records` to the window relative to `now`.
    static func inWindow(
        _ records: [DraftFeedbackRecord],
        window: DraftFeedbackWindow,
        now: Date = Date()
    ) -> [DraftFeedbackRecord] {
        guard let days = window.days else { return records }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return records.filter { $0.timestamp >= cutoff }
    }
}
