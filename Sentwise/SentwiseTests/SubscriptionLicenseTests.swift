import XCTest
@testable import Sentwise

/// Offline license grace for item 56c: the entitlement evaluator, the durable
/// snapshot's lenient decoding, and the UserDefaults-backed cache round-trip.
final class SubscriptionLicenseTests: XCTestCase {

    private let now = ManagedQuotaDate.date(from: "2026-09-05T00:00:00Z")!

    // MARK: - Entitlement mapping

    func testEntitledStatuses() {
        XCTAssertTrue(SubscriptionLicenseEvaluator.isEntitled(.active))
        XCTAssertTrue(SubscriptionLicenseEvaluator.isEntitled(.trialing))
        XCTAssertFalse(SubscriptionLicenseEvaluator.isEntitled(.pastDue))
        XCTAssertFalse(SubscriptionLicenseEvaluator.isEntitled(.canceled))
        XCTAssertFalse(SubscriptionLicenseEvaluator.isEntitled(.lapsed))
        XCTAssertFalse(SubscriptionLicenseEvaluator.isEntitled(.unknown))
    }

    // MARK: - Live status wins

    func testLiveActiveIsEntitled() {
        let license = SubscriptionLicenseEvaluator.evaluate(liveStatus: .active, cached: nil, now: now)
        XCTAssertEqual(license, .entitled)
    }

    func testLiveCanceledIsNotEntitledEvenWithEntitledCache() {
        let cached = snapshot(status: .active, capturedAt: now)
        let license = SubscriptionLicenseEvaluator.evaluate(liveStatus: .canceled, cached: cached, now: now)
        XCTAssertEqual(license, .notEntitled)
    }

    // MARK: - Offline grace (live status unavailable)

    func testOfflineWithinGraceReturnsGrace() {
        // Captured 2 days ago; default grace is 7 days -> ~5 days remaining.
        let captured = now.addingTimeInterval(-2 * 86_400)
        let cached = snapshot(status: .active, capturedAt: captured)
        let license = SubscriptionLicenseEvaluator.evaluate(liveStatus: nil, cached: cached, now: now)
        guard case .grace(let days) = license else { return XCTFail("expected grace, got \(license)") }
        XCTAssertEqual(days, 5)
    }

    func testCachedTrialPastKnownEndDoesNotGrace() {
        let cached = SubscriptionSnapshot(
            plan: .trial,
            status: .trialing,
            renewsAt: now.addingTimeInterval(-1),
            capturedAt: now.addingTimeInterval(-2 * 86_400)
        )
        let license = SubscriptionLicenseEvaluator.evaluate(liveStatus: nil, cached: cached, now: now)
        XCTAssertEqual(license, .unknown)
    }

    func testCachedTrialBeforeKnownEndCanGrace() {
        let cached = SubscriptionSnapshot(
            plan: .trial,
            status: .trialing,
            renewsAt: now.addingTimeInterval(86_400),
            capturedAt: now.addingTimeInterval(-2 * 86_400)
        )
        let license = SubscriptionLicenseEvaluator.evaluate(liveStatus: nil, cached: cached, now: now)
        guard case .grace(let days) = license else { return XCTFail("expected grace, got \(license)") }
        XCTAssertEqual(days, 5)
    }

    func testOfflinePastGraceReturnsUnknown() {
        let captured = now.addingTimeInterval(-10 * 86_400) // beyond 7-day grace
        let cached = snapshot(status: .active, capturedAt: captured)
        let license = SubscriptionLicenseEvaluator.evaluate(liveStatus: nil, cached: cached, now: now)
        XCTAssertEqual(license, .unknown)
    }

    func testOfflineWithNotEntitledCacheIsNotEntitled() {
        let cached = snapshot(status: .lapsed, capturedAt: now)
        let license = SubscriptionLicenseEvaluator.evaluate(liveStatus: nil, cached: cached, now: now)
        XCTAssertEqual(license, .notEntitled)
    }

    func testOfflineWithNoCacheIsUnknown() {
        let license = SubscriptionLicenseEvaluator.evaluate(liveStatus: nil, cached: nil, now: now)
        XCTAssertEqual(license, .unknown)
    }

    func testUnknownLiveStatusFallsBackToCache() {
        let cached = snapshot(status: .active, capturedAt: now)
        let license = SubscriptionLicenseEvaluator.evaluate(liveStatus: .unknown, cached: cached, now: now)
        guard case .grace = license else { return XCTFail("unknown live status should defer to cache grace") }
    }

    // MARK: - Snapshot capture & decoding

    func testSnapshotFromSubscriptionCapturesFields() {
        let sub = ManagedSubscription(
            plan: .pro, status: .active,
            renewsAt: now, manageBillingURL: "https://billing.example/portal"
        )
        let snapshot = SubscriptionSnapshot(subscription: sub, capturedAt: now)
        XCTAssertEqual(snapshot?.plan, .pro)
        XCTAssertEqual(snapshot?.status, .active)
        XCTAssertEqual(snapshot?.manageBillingURL, "https://billing.example/portal")
    }

    func testSnapshotFromNilSubscriptionIsNil() {
        XCTAssertNil(SubscriptionSnapshot(subscription: nil))
    }

    func testSnapshotDecodesUnknownPlanAndStatusLeniently() throws {
        let json = #"{"plan":"enterprise","status":"grace_period","capturedAt":0}"#
        let snapshot = try JSONDecoder().decode(SubscriptionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.plan, .unknown)
        XCTAssertEqual(snapshot.status, .unknown)
    }

    // MARK: - Store round-trip

    func testUserDefaultsStoreRoundTripsPerAccount() {
        let suite = UserDefaults(suiteName: "PaddleLicenseTests-\(UUID().uuidString)")!
        let store = UserDefaultsSubscriptionCacheStore(defaults: suite)
        let snapshot = snapshot(status: .active, capturedAt: now)

        XCTAssertNil(store.snapshot(accountKey: "acct-A"))
        store.save(snapshot, accountKey: "acct-A")
        XCTAssertEqual(store.snapshot(accountKey: "acct-A")?.status, .active)
        // Isolation: a different account key sees nothing.
        XCTAssertNil(store.snapshot(accountKey: "acct-B"))

        store.clear(accountKey: "acct-A")
        XCTAssertNil(store.snapshot(accountKey: "acct-A"))
    }

    // MARK: - Helpers

    private func snapshot(status: ManagedSubscription.Status, capturedAt: Date) -> SubscriptionSnapshot {
        SubscriptionSnapshot(plan: .pro, status: status, capturedAt: capturedAt)
    }
}
