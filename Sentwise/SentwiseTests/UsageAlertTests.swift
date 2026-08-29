import XCTest
@testable import Sentwise

/// Idempotence, window-reset, and copy tests for the usage-alert logic (item 56b).
final class UsageAlertTests: XCTestCase {

    private let window = ManagedQuotaDate.date(from: "2025-09-01T00:00:00Z")!
    private let nextWindow = ManagedQuotaDate.date(from: "2025-09-08T00:00:00Z")!

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
        let outcome = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 50), previous: nil)
        XCTAssertEqual(outcome.fire, [.fifty])
        XCTAssertEqual(outcome.newState.firedThresholds, [50])
        XCTAssertEqual(outcome.newState.windowResetsAt, window)
    }

    func testCrossingMultipleThresholdsAtOnceFiresAllUnfired() {
        let outcome = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 100), previous: nil)
        XCTAssertEqual(outcome.fire, [.fifty, .seventyFive, .hundred])
        XCTAssertEqual(outcome.newState.firedThresholds, [50, 75, 100])
    }

    func testBelowFiftyFiresNothing() {
        let outcome = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 40), previous: nil)
        XCTAssertTrue(outcome.fire.isEmpty)
        XCTAssertTrue(outcome.newState.firedThresholds.isEmpty)
    }

    // MARK: - Idempotence

    func testDoesNotRefireAlreadyFiredThreshold() {
        let first = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 55), previous: nil)
        XCTAssertEqual(first.fire, [.fifty])

        // A later report in the SAME window still over 50 but not yet 75.
        let second = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 60), previous: first.newState)
        XCTAssertTrue(second.fire.isEmpty)
        XCTAssertEqual(second.newState.firedThresholds, [50])
    }

    func testFiresOnlyTheNewlyCrossedThreshold() {
        let first = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 55), previous: nil)
        let second = UsageAlertEvaluator.evaluate(quota: quota(usedPercent: 80), previous: first.newState)
        XCTAssertEqual(second.fire, [.seventyFive])
        XCTAssertEqual(second.newState.firedThresholds, [50, 75])
    }

    // MARK: - Window reset

    func testWindowRolloverResetsFiredThresholds() {
        let priorWindow = UsageAlertState(windowResetsAt: window, firedThresholds: [50, 75, 100])
        // New window, back down to 55% — 50 fires again in the fresh window.
        let outcome = UsageAlertEvaluator.evaluate(
            quota: quota(usedPercent: 55, resetsAt: nextWindow),
            previous: priorWindow
        )
        XCTAssertEqual(outcome.fire, [.fifty])
        XCTAssertEqual(outcome.newState.windowResetsAt, nextWindow)
        XCTAssertEqual(outcome.newState.firedThresholds, [50])
    }

    // MARK: - Guards

    func testUnknownResetFiresNothing() {
        let quota = ManagedQuota(used: 100, limit: 100, remaining: 0, resetsAt: .distantPast)
        let outcome = UsageAlertEvaluator.evaluate(quota: quota, previous: nil)
        XCTAssertTrue(outcome.fire.isEmpty)
    }

    func testZeroLimitFiresNothing() {
        let quota = ManagedQuota(used: 5, limit: 0, remaining: 0, resetsAt: window)
        let outcome = UsageAlertEvaluator.evaluate(quota: quota, previous: nil)
        XCTAssertTrue(outcome.fire.isEmpty)
    }

    // MARK: - Copy

    func testHundredPercentSoftCopyKeepsDrafting() {
        let alert = UsageAlert.make(threshold: .hundred, quota: quota(usedPercent: 100, enforcement: .soft))
        XCTAssertTrue(alert.body.contains("Drafting continues"), alert.body)
        XCTAssertTrue(alert.body.contains("your own key"), alert.body)
    }

    func testHundredPercentHardCopyPointsToBuyMore() {
        let alert = UsageAlert.make(threshold: .hundred, quota: quota(usedPercent: 100, enforcement: .hard))
        XCTAssertTrue(alert.body.contains("Buy more usage"), alert.body)
    }

    func testAlertIdentifierIsStablePerThresholdAndWindow() {
        let fifty = UsageAlert.make(threshold: .fifty, quota: quota(usedPercent: 50))
        let fiftyLater = UsageAlert.make(threshold: .fifty, quota: quota(usedPercent: 60))
        XCTAssertEqual(fifty.identifier, fiftyLater.identifier,
                       "same threshold + window should share an id so re-posts replace")

        let differentThreshold = UsageAlert.make(threshold: .seventyFive, quota: quota(usedPercent: 75))
        XCTAssertNotEqual(fifty.identifier, differentThreshold.identifier)

        let differentWindow = UsageAlert.make(threshold: .fifty, quota: quota(usedPercent: 50, resetsAt: nextWindow))
        XCTAssertNotEqual(fifty.identifier, differentWindow.identifier)
    }
}
