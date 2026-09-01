import XCTest
@testable import Sentwise

/// Tests for the pure on-device analytics aggregator (item 84) over the item-83
/// feedback store: rates, windowing by timestamp, edit-magnitude averaging,
/// deny-reason counts, the answered-then-approved signal, and the empty/single
/// edge cases.
final class DraftFeedbackStatsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_756_512_000)

    // MARK: - Record builders

    private func record(
        outcome: DraftFeedbackOutcome,
        daysAgo: Double,
        editMagnitude: Double? = nil,
        denyCode: DenyReasonCode? = nil,
        answered: Bool = false
    ) -> DraftFeedbackRecord {
        DraftFeedbackRecord(
            timestamp: now.addingTimeInterval(-daysAgo * 86_400),
            outcome: outcome,
            editMagnitude: editMagnitude,
            denyReason: denyCode.map { DenyReason(code: $0) },
            provenance: .watcher,
            answeredNeedsInfo: answered,
            draftIdentityHash: DraftFeedbackRecord.hashedIdentity("id-\(UUID().uuidString)")
        )
    }

    // MARK: - Empty / single

    func testEmptyStoreYieldsZeroedStats() {
        let stats = DraftFeedbackStats.compute(records: [], window: .allTime, now: now)
        XCTAssertEqual(stats.decidedCount, 0)
        XCTAssertEqual(stats.oneShotAcceptRate, 0)
        XCTAssertEqual(stats.editedRate, 0)
        XCTAssertEqual(stats.deniedRate, 0)
        XCTAssertNil(stats.averageEditMagnitude)
        XCTAssertEqual(stats.answeredThenApprovedCount, 0)
        XCTAssertEqual(DraftFeedbackStats.totalRecordCount([]), 0)
        // Every reason code key is still present (0) for a stable display.
        XCTAssertEqual(stats.denyReasonCounts.count, DenyReasonCode.allCases.count)
        XCTAssertTrue(stats.denyReasonCounts.values.allSatisfy { $0 == 0 })
    }

    func testSingleApprovedAsIsRecord() {
        let stats = DraftFeedbackStats.compute(
            records: [record(outcome: .approvedAsIs, daysAgo: 1)],
            window: .allTime, now: now
        )
        XCTAssertEqual(stats.decidedCount, 1)
        XCTAssertEqual(stats.oneShotAcceptRate, 1.0)
        XCTAssertEqual(stats.editedRate, 0)
        XCTAssertEqual(stats.deniedRate, 0)
    }

    // MARK: - Rates over decided drafts (abandoned excluded)

    func testRatesExcludeAbandonedFromDenominator() {
        let records = [
            record(outcome: .approvedAsIs, daysAgo: 1),
            record(outcome: .approvedAsIs, daysAgo: 1),
            record(outcome: .approvedAfterEdit, daysAgo: 1, editMagnitude: 0.3),
            record(outcome: .denied, daysAgo: 1, denyCode: .wrongTone),
            // Two abandoned previews must NOT dilute the rates.
            record(outcome: .abandoned, daysAgo: 1),
            record(outcome: .abandoned, daysAgo: 1)
        ]
        let stats = DraftFeedbackStats.compute(records: records, window: .allTime, now: now)
        XCTAssertEqual(stats.decidedCount, 4)
        XCTAssertEqual(stats.abandonedCount, 2)
        XCTAssertEqual(stats.oneShotAcceptRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(stats.editedRate, 0.25, accuracy: 0.0001)
        XCTAssertEqual(stats.deniedRate, 0.25, accuracy: 0.0001)
        // The three rates sum to ~1.
        XCTAssertEqual(stats.oneShotAcceptRate + stats.editedRate + stats.deniedRate, 1.0, accuracy: 0.0001)
    }

    // MARK: - Windowing honors timestamps

    func testWindowsHonorTimestamps() {
        let records = [
            record(outcome: .approvedAsIs, daysAgo: 1),    // in 7d, 30d, all
            record(outcome: .approvedAsIs, daysAgo: 8),    // in 30d, all
            record(outcome: .denied, daysAgo: 40, denyCode: .handleLater) // all only
        ]
        let last7 = DraftFeedbackStats.compute(records: records, window: .last7Days, now: now)
        let last30 = DraftFeedbackStats.compute(records: records, window: .last30Days, now: now)
        let all = DraftFeedbackStats.compute(records: records, window: .allTime, now: now)
        XCTAssertEqual(last7.decidedCount, 1)
        XCTAssertEqual(last30.decidedCount, 2)
        XCTAssertEqual(all.decidedCount, 3)
        // The 40-day-old denial only appears in all-time.
        XCTAssertEqual(all.deniedCount, 1)
        XCTAssertEqual(last30.deniedCount, 0)
    }

    func testWindowBoundaryIsInclusive() {
        // Exactly 7 days old sits on the cutoff and is included in last-7.
        let records = [record(outcome: .approvedAsIs, daysAgo: 7)]
        let last7 = DraftFeedbackStats.compute(records: records, window: .last7Days, now: now)
        XCTAssertEqual(last7.decidedCount, 1)
    }

    // MARK: - Average edit magnitude

    func testAverageEditMagnitudeOverEditedApprovalsOnly() {
        let records = [
            record(outcome: .approvedAfterEdit, daysAgo: 1, editMagnitude: 0.2),
            record(outcome: .approvedAfterEdit, daysAgo: 1, editMagnitude: 0.4),
            // An edited approval with no stored magnitude is ignored by the average.
            record(outcome: .approvedAfterEdit, daysAgo: 1, editMagnitude: nil),
            // As-is approvals never contribute.
            record(outcome: .approvedAsIs, daysAgo: 1)
        ]
        let stats = DraftFeedbackStats.compute(records: records, window: .allTime, now: now)
        XCTAssertEqual(stats.averageEditMagnitude ?? -1, 0.3, accuracy: 0.0001)
    }

    func testAverageEditMagnitudeNilWhenNoEditedApprovals() {
        let stats = DraftFeedbackStats.compute(
            records: [record(outcome: .approvedAsIs, daysAgo: 1)],
            window: .allTime, now: now
        )
        XCTAssertNil(stats.averageEditMagnitude)
    }

    // MARK: - Deny-reason breakdown

    func testDenyReasonCountsByCode() {
        let records = [
            record(outcome: .denied, daysAgo: 1, denyCode: .wrongTone),
            record(outcome: .denied, daysAgo: 1, denyCode: .wrongTone),
            record(outcome: .denied, daysAgo: 1, denyCode: .notWorthReplying),
            // A legacy denial with no reason counts toward deniedCount but no code.
            record(outcome: .denied, daysAgo: 1, denyCode: nil)
        ]
        let stats = DraftFeedbackStats.compute(records: records, window: .allTime, now: now)
        XCTAssertEqual(stats.deniedCount, 4)
        XCTAssertEqual(stats.denyReasonCounts[.wrongTone], 2)
        XCTAssertEqual(stats.denyReasonCounts[.notWorthReplying], 1)
        XCTAssertEqual(stats.denyReasonCounts[.wrongContent], 0)
        XCTAssertEqual(stats.denyReasonCounts[.handleLater], 0)
        XCTAssertEqual(stats.denyReasonCounts[.other], 0)
        // Reason codes counted (3) can be fewer than denials (4) — the legacy one.
        let codedTotal = stats.denyReasonCounts.values.reduce(0, +)
        XCTAssertEqual(codedTotal, 3)
    }

    // MARK: - Answered-then-approved (item 85 signal)

    func testAnsweredThenApprovedCountsApprovalsOnly() {
        let records = [
            record(outcome: .approvedAsIs, daysAgo: 1, answered: true),
            record(outcome: .approvedAfterEdit, daysAgo: 1, editMagnitude: 0.1, answered: true),
            // Answered but denied — not an approval, so not counted.
            record(outcome: .denied, daysAgo: 1, denyCode: .wrongContent, answered: true),
            // Approved but not answered — not counted.
            record(outcome: .approvedAsIs, daysAgo: 1, answered: false)
        ]
        let stats = DraftFeedbackStats.compute(records: records, window: .allTime, now: now)
        XCTAssertEqual(stats.answeredThenApprovedCount, 2)
    }
}
