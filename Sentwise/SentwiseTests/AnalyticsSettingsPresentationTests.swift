import XCTest
@testable import Sentwise

/// Tests for the Analytics tab's quota presentation, its Settings-tab wiring, and
/// the Prowl hunt-mode fixture determinism (item 84).
final class AnalyticsSettingsPresentationTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private let locale = Locale(identifier: "en_US")

    private func quota(
        used: Int = 12,
        limit: Int = 50,
        remaining: Int = 38,
        resetsAt: Date = Date(timeIntervalSince1970: 1_756_512_000),
        tokensUsed: Int = 125_000,
        tokenLimit: Int = 250_000,
        extraPurchased: Int = 0
    ) -> ManagedQuota {
        ManagedQuota(
            used: used, limit: limit, remaining: remaining, resetsAt: resetsAt,
            tokensUsed: tokensUsed, tokenLimit: tokenLimit, extraPurchased: extraPurchased
        )
    }

    // MARK: - Quota presentation

    func testPresentationIsNilWhenQuotaUnknown() {
        XCTAssertNil(AnalyticsQuotaPresentation.make(from: nil))
    }

    func testPresentationMapsDraftAndTokenNumbers() {
        let p = AnalyticsQuotaPresentation.make(from: quota(), calendar: calendar, locale: locale)
        XCTAssertEqual(p?.draftsUsed, 12)
        XCTAssertEqual(p?.limit, 50)
        XCTAssertEqual(p?.remaining, 38)
        XCTAssertEqual(p?.draftsSummary, "12 of 50 drafts used · 38 remaining")
        // Tokens are a subdued caption with grouping; the UI unit is drafts.
        XCTAssertEqual(p?.tokensCaption, "125,000 of 250,000 tokens used")
    }

    func testExtraPurchasedRowOnlyWhenPositive() {
        let none = AnalyticsQuotaPresentation.make(from: quota(extraPurchased: 0))
        XCTAssertNil(none?.extraPurchasedRow)

        let some = AnalyticsQuotaPresentation.make(from: quota(extraPurchased: 3))
        XCTAssertEqual(some?.extraPurchasedRow, "Extra usage purchased this window: 3")
    }

    func testResetTextHiddenWhenResetUnknown() {
        let unknown = AnalyticsQuotaPresentation.make(
            from: quota(resetsAt: .distantPast), calendar: calendar, locale: locale
        )
        XCTAssertNil(unknown?.resetText)

        let known = AnalyticsQuotaPresentation.make(
            from: quota(), calendar: calendar, locale: locale
        )
        XCTAssertEqual(known?.resetText?.hasPrefix("resets "), true)
    }

    // MARK: - Settings tab wiring

    func testAnalyticsTabExistsAfterSubscription() {
        let cases = SettingsTab.allCases
        guard let subIndex = cases.firstIndex(of: .subscription),
              let analyticsIndex = cases.firstIndex(of: .analytics) else {
            return XCTFail("Both Subscription and Analytics tabs must exist")
        }
        XCTAssertEqual(analyticsIndex, subIndex + 1, "Analytics is placed right after Subscription")
        XCTAssertEqual(SettingsTab.analytics.rawValue, "Analytics")
        XCTAssertFalse(SettingsTab.analytics.icon.isEmpty)
    }

    // MARK: - Prowl hunt-mode determinism

    func testHuntFixtureProducesDeterministicInsights() {
        let now = Date(timeIntervalSince1970: 1_756_512_000)
        let records = ProwlHuntRuntime.fixtureDraftFeedback(now: now)

        // Nine records total → above the 3-record empty-state threshold.
        XCTAssertEqual(DraftFeedbackStats.totalRecordCount(records), 9)

        // All fixtures fall within the last day, so every window is identical.
        for window in DraftFeedbackWindow.allCases {
            let stats = DraftFeedbackStats.compute(records: records, window: window, now: now)
            XCTAssertEqual(stats.decidedCount, 8, "\(window)")
            XCTAssertEqual(stats.oneShotAcceptRate, 0.5, accuracy: 0.0001, "\(window)")
            XCTAssertEqual(stats.editedRate, 0.25, accuracy: 0.0001, "\(window)")
            XCTAssertEqual(stats.deniedRate, 0.25, accuracy: 0.0001, "\(window)")
            XCTAssertEqual(stats.averageEditMagnitude ?? -1, 0.3, accuracy: 0.0001, "\(window)")
            XCTAssertEqual(stats.answeredThenApprovedCount, 2, "\(window)")
            XCTAssertEqual(stats.abandonedCount, 1, "\(window)")
            XCTAssertEqual(stats.denyReasonCounts[.wrongTone], 1, "\(window)")
            XCTAssertEqual(stats.denyReasonCounts[.notWorthReplying], 1, "\(window)")
        }
    }

    func testHuntPersistenceProviderSeedsFeedbackStore() {
        let runtime = ProwlHuntRuntime(isEnabled: true)
        let persistence = runtime.makePersistenceProvider()
        // The fixture store is seeded (>= 3) so the insights section renders, and
        // all identities are hashed — no message content is present.
        let records = persistence.loadDraftFeedback()
        XCTAssertEqual(records.count, 9)
        XCTAssertTrue(records.allSatisfy { $0.draftIdentityHash.count == 64 })
    }
}
