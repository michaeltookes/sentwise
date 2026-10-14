import XCTest
@testable import Sentwise

@MainActor
final class GoogleRevocationTrackerTests: XCTestCase {
    func testRevocationIsRegisteredBeforeItsTaskRunsAndClearsOnCompletion() async {
        let tracker = GoogleRevocationTracker()
        var didRun = false

        let task = tracker.start { didRun = true }

        XCTAssertTrue(tracker.hasPending)
        XCTAssertFalse(didRun, "registration must not require the background task to start")
        await task.value
        XCTAssertTrue(didRun)
        XCTAssertFalse(tracker.hasPending)
        let finished = await tracker.waitForPending(timeout: 0)
        XCTAssertTrue(finished)
    }
}
