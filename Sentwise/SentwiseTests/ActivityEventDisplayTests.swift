import XCTest
@testable import Sentwise

final class ActivityEventDisplayTests: XCTestCase {

    func testActivityDetailVisibilityIncludesSaveFailuresAndEditNotes() {
        XCTAssertTrue(ActivityEventKind.sendFailed.showsFailureDetail)
        XCTAssertTrue(ActivityEventKind.saveFailed.showsFailureDetail)
        XCTAssertFalse(ActivityEventKind.approvedSaved.showsFailureDetail)
        XCTAssertTrue(ActivityEventKind.approvedSent.showsSuccessDetail)
        XCTAssertTrue(ActivityEventKind.approvedSaved.showsSuccessDetail)
        XCTAssertTrue(ActivityEventKind.denied.showsSuccessDetail)
        XCTAssertFalse(ActivityEventKind.saveFailed.showsSuccessDetail)
    }

    func testActivityAccessibilityLabelIncludesVisibleDetail() {
        let event = ActivityEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .approvedSent,
            sender: "Alice",
            subject: "Lunch?",
            detail: "Edited before send"
        )

        XCTAssertTrue(event.activityHistoryAccessibilityLabel.contains("Edited before send"))
    }

    func testDeniedActivityVisibleDetailFormatsReasonCode() {
        let event = ActivityEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .denied,
            sender: "Alice",
            subject: "Lunch?",
            detail: DenyReasonCode.wrongTone.rawValue
        )

        XCTAssertEqual(event.activityHistoryVisibleDetail, "Reason: Wrong tone")
        XCTAssertTrue(event.activityHistoryAccessibilityLabel.contains("Reason: Wrong tone"))
    }
}
