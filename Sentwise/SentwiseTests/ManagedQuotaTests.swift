import XCTest
@testable import Sentwise

/// Decoding, derived-value, and display tests for `ManagedQuota` (backlog item 56b).
final class ManagedQuotaTests: XCTestCase {

    private func decode(_ json: String) throws -> ManagedQuota {
        try JSONDecoder().decode(ManagedQuota.self, from: Data(json.utf8))
    }

    // MARK: - Decoding

    func testDecodesFullQuota() throws {
        let quota = try decode(#"""
        {
          "unit": "drafts",
          "used": 12,
          "limit": 50,
          "remaining": 38,
          "resetsAt": "2025-09-01T00:00:00Z",
          "tokensUsed": 60000,
          "tokenLimit": 250000,
          "enforcement": "hard",
          "extraPurchased": 3
        }
        """#)

        XCTAssertEqual(quota.unit, "drafts")
        XCTAssertEqual(quota.used, 12)
        XCTAssertEqual(quota.limit, 50)
        XCTAssertEqual(quota.remaining, 38)
        XCTAssertEqual(quota.tokensUsed, 60000)
        XCTAssertEqual(quota.tokenLimit, 250000)
        XCTAssertEqual(quota.enforcement, .hard)
        XCTAssertEqual(quota.extraPurchased, 3)
        XCTAssertEqual(quota.resetsAt, ManagedQuotaDate.date(from: "2025-09-01T00:00:00Z"))
    }

    func testDecodesQuotaWithFractionalSecondsResetsAt() throws {
        let quota = try decode(#"""
        {"unit":"drafts","used":1,"limit":10,"remaining":9,
         "resetsAt":"2025-09-01T00:00:00.500Z","enforcement":"soft"}
        """#)
        XCTAssertTrue(quota.hasKnownReset)
        XCTAssertEqual(quota.resetsAt, ManagedQuotaDate.date(from: "2025-09-01T00:00:00.500Z"))
    }

    /// Older Worker builds omit the whole `quota` object — the *containing* type
    /// treats it as optional. Here we prove a present-but-sparse object still
    /// decodes with sane defaults (lenient per the wire contract).
    func testDecodesSparseQuotaWithDefaults() throws {
        let quota = try decode(#"{"used":5,"limit":20}"#)
        XCTAssertEqual(quota.unit, "drafts")
        XCTAssertEqual(quota.used, 5)
        XCTAssertEqual(quota.limit, 20)
        // remaining defaults to limit − used when absent.
        XCTAssertEqual(quota.remaining, 15)
        XCTAssertEqual(quota.enforcement, .soft)
        XCTAssertEqual(quota.extraPurchased, 0)
        XCTAssertFalse(quota.hasKnownReset)
    }

    func testUnknownEnforcementDefaultsToSoft() throws {
        let quota = try decode(#"{"used":1,"limit":10,"resetsAt":"2025-09-01T00:00:00Z","enforcement":"mystery"}"#)
        XCTAssertEqual(quota.enforcement, .soft)
    }

    func testQuotaIsOptionalWhenAbsentFromContainer() throws {
        struct Envelope: Decodable { let quota: ManagedQuota? }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(#"{"text":"hi"}"#.utf8))
        XCTAssertNil(envelope.quota)
    }

    func testRoundTripsThroughCodable() throws {
        let original = ManagedQuota(
            unit: "drafts",
            used: 7,
            limit: 40,
            remaining: 33,
            resetsAt: ManagedQuotaDate.date(from: "2025-09-01T00:00:00Z")!,
            tokensUsed: 1000,
            tokenLimit: 5000,
            enforcement: .hard,
            extraPurchased: 2
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ManagedQuota.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Derived values

    func testUsedFractionAndPercent() {
        let quota = makeQuota(used: 30, limit: 40)
        XCTAssertEqual(quota.usedFraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(quota.usedPercent, 75)
    }

    func testUsedFractionClampsOverLimit() {
        let quota = makeQuota(used: 60, limit: 40)
        XCTAssertEqual(quota.usedFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(quota.usedPercent, 150) // percent is uncapped for threshold logic
    }

    func testZeroLimitIsSafe() {
        let quota = makeQuota(used: 5, limit: 0)
        XCTAssertEqual(quota.usedFraction, 0)
        XCTAssertEqual(quota.usedPercent, 0)
    }

    // MARK: - Display

    func testUsageSummaryIncludesCountsAndReset() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let quota = ManagedQuota(
            unit: "drafts",
            used: 12,
            limit: 50,
            remaining: 38,
            resetsAt: ManagedQuotaDate.date(from: "2025-09-01T00:00:00Z")!, // a Monday, UTC
            enforcement: .soft
        )
        let summary = quota.usageSummary(calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertTrue(summary.hasPrefix("12 of 50 drafts used this week"), summary)
        XCTAssertTrue(summary.contains("resets"), summary)
        XCTAssertTrue(summary.contains("Monday"), summary)
    }

    func testUsageSummaryOmitsResetWhenUnknown() {
        let quota = ManagedQuota(used: 3, limit: 10, resetsAt: .distantPast)
        let summary = quota.usageSummary()
        XCTAssertEqual(summary, "3 of 10 drafts used this week")
        XCTAssertFalse(summary.contains("resets"))
    }

    // MARK: - Helpers

    private func makeQuota(used: Int, limit: Int) -> ManagedQuota {
        ManagedQuota(used: used, limit: limit, remaining: max(0, limit - used), resetsAt: .distantPast)
    }
}
