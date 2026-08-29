import XCTest
@testable import Sentwise

/// Idempotence, window-reset, and copy tests for the usage-alert logic (item 56b).
final class UsageAlertTests: XCTestCase {

    private let window = ManagedQuotaDate.date(from: "2025-09-01T00:00:00Z")!
    private let nextWindow = ManagedQuotaDate.date(from: "2025-09-08T00:00:00Z")!
    private let accountA = "acct-a"
    private let accountB = "acct-b"

    private func quota(usedPercent percent: Int, enforcement: ManagedQuota.Enforcement = .soft, resetsAt: Date? = nil) -> ManagedQuota {
        let limit = 100
        return ManagedQuota(
            unit: "drafts",
            used: percent,
            limit: limit,
            remaining: max(0, limit - percent),
            resetsAt: resetsAt ?? window,
            enforcement: enforcement
        )
    }

    // MARK: - Threshold crossing

    func testFiresFiftyOnceAtHalf() {
        let outcome = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 50), previous: nil, accountKey: accountA)
        XCTAssertEqual(outcome.fire, [.fifty])
        XCTAssertEqual(outcome.newState.firedThresholds, [50])
        XCTAssertEqual(outcome.newState.accountKey, accountA)
        XCTAssertEqual(outcome.newState.windowResetsAt, window)
    }

    func testCrossingMultipleThresholdsAtOnceFiresAllUnfired() {
        let outcome = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 100), previous: nil, accountKey: accountA)
        XCTAssertEqual(outcome.fire, [.fifty, .seventyFive, .hundred])
        XCTAssertEqual(outcome.newState.firedThresholds, [50, 75, 100])
    }

    func testBelowFiftyFiresNothing() {
        let outcome = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 40), previous: nil, accountKey: accountA)
        XCTAssertTrue(outcome.fire.isEmpty)
        XCTAssertTrue(outcome.newState.firedThresholds.isEmpty)
    }

    // MARK: - Idempotence

    func testDoesNotRefireAlreadyFiredThreshold() {
        let first = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 55), previous: nil, accountKey: accountA)
        XCTAssertEqual(first.fire, [.fifty])

        // A later report in the SAME window still over 50 but not yet 75.
        let second = UsageAlertEvaluator.evaluate(
            quota: quota(usedPercent: 60),
            previous: first.newState,
            accountKey: accountA
        )
        XCTAssertTrue(second.fire.isEmpty)
        XCTAssertEqual(second.newState.firedThresholds, [50])
    }

    func testFiresOnlyTheNewlyCrossedThreshold() {
        let first = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 55), previous: nil, accountKey: accountA)
        let second = UsageAlertEvaluator.evaluate(
            quota: quota(usedPercent: 80),
            previous: first.newState,
            accountKey: accountA
        )
        XCTAssertEqual(second.fire, [.seventyFive])
        XCTAssertEqual(second.newState.firedThresholds, [50, 75])
    }

    func testAccountChangeResetsFiredThresholdsForSameWindow() {
        let first = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 55), previous: nil, accountKey: accountA)
        let second = UsageAlertEvaluator.evaluate(
            quota: quota(usedPercent: 60),
            previous: first.newState,
            accountKey: accountB
        )
        XCTAssertEqual(second.fire, [.fifty])
        XCTAssertEqual(second.newState.accountKey, accountB)
        XCTAssertEqual(second.newState.windowResetsAt, window)
        XCTAssertEqual(second.newState.firedThresholds, [50])
    }

    // MARK: - Window reset

    func testWindowRolloverResetsFiredThresholds() {
        let priorWindow = UsageAlertState(accountKey: accountA, windowResetsAt: window, firedThresholds: [50, 75, 100])
        // New window, back down to 55% — 50 fires again in the fresh window.
        let outcome = UsageAlertEvaluator.evaluate(
            quota: quota(usedPercent: 55, resetsAt: nextWindow),
            previous: priorWindow,
            accountKey: accountA
        )
        XCTAssertEqual(outcome.fire, [.fifty])
        XCTAssertEqual(outcome.newState.windowResetsAt, nextWindow)
        XCTAssertEqual(outcome.newState.firedThresholds, [50])
    }

    // MARK: - Guards

    func testUnknownResetFiresNothing() {
        let quota = ManagedQuota(used: 100, limit: 100, remaining: 0, resetsAt: .distantPast)
        let outcome = UsageAlertEvaluator.evaluate(quota: quota, previous: nil, accountKey: accountA)
        XCTAssertTrue(outcome.fire.isEmpty)
    }

    func testZeroLimitFiresNothing() {
        let quota = ManagedQuota(used: 5, limit: 0, remaining: 0, resetsAt: window)
        let outcome = UsageAlertEvaluator.evaluate(quota: quota, previous: nil, accountKey: accountA)
        XCTAssertTrue(outcome.fire.isEmpty)
    }

    // MARK: - Copy

    func testHundredPercentSoftCopyKeepsDrafting() {
        let alert = UsageAlert.make(
            threshold: .hundred,
            quota: quota(usedPercent: 100, enforcement: .soft),
            accountKey: accountA
        )
        XCTAssertTrue(alert.body.contains("Drafting continues"), alert.body)
        XCTAssertTrue(alert.body.contains("your own key"), alert.body)
    }

    func testHundredPercentHardCopyPointsToBuyMore() {
        let alert = UsageAlert.make(
            threshold: .hundred,
            quota: quota(usedPercent: 100, enforcement: .hard),
            accountKey: accountA
        )
        XCTAssertTrue(alert.body.contains("Buy more usage"), alert.body)
    }

    func testAlertIdentifierIsStablePerThresholdAndWindow() {
        let fifty = UsageAlert.make(threshold: .fifty, quota: quota(usedPercent: 50), accountKey: accountA)
        let fiftyLater = UsageAlert.make(threshold: .fifty, quota: quota(usedPercent: 60), accountKey: accountA)
        XCTAssertEqual(fifty.identifier, fiftyLater.identifier,
                       "same threshold + window should share an id so re-posts replace")

        let differentThreshold = UsageAlert.make(
            threshold: .seventyFive,
            quota: quota(usedPercent: 75),
            accountKey: accountA
        )
        XCTAssertNotEqual(fifty.identifier, differentThreshold.identifier)

        let differentWindow = UsageAlert.make(
            threshold: .fifty,
            quota: quota(usedPercent: 50, resetsAt: nextWindow),
            accountKey: accountA
        )
        XCTAssertNotEqual(fifty.identifier, differentWindow.identifier)

        let differentAccount = UsageAlert.make(threshold: .fifty, quota: quota(usedPercent: 50), accountKey: accountB)
        XCTAssertNotEqual(fifty.identifier, differentAccount.identifier)
    }

    // MARK: - Store

    func testUserDefaultsStorePreservesStateForMultipleAccounts() throws {
        let suiteName = "UsageAlertTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsUsageAlertStore(defaults: defaults, key: "usage-alert-test")

        store.save(UsageAlertState(accountKey: accountA, windowResetsAt: window, firedThresholds: [50]))
        store.save(UsageAlertState(accountKey: accountB, windowResetsAt: window, firedThresholds: [50, 75]))

        XCTAssertEqual(store.loadState(for: accountA)?.firedThresholds, [50])
        XCTAssertEqual(store.loadState(for: accountB)?.firedThresholds, [50, 75])
    }
}
