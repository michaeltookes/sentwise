import XCTest
@testable import Sentwise

/// Model-level tests for the feedback record (item 83, Phase 1): the hashed draft
/// identity, the stable reason codes, and the no-PII stance of the stored shape.
final class DraftFeedbackRecordTests: XCTestCase {

    func testHashedIdentityIsStableSHA256Hex() {
        let identity = "me@gmail.com|INBOX|10|42"
        let hash = DraftFeedbackRecord.hashedIdentity(identity)
        // 32-byte SHA-256 → 64 lowercase hex chars, deterministic.
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, DraftFeedbackRecord.hashedIdentity(identity))
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // Never leaks the identity (which embeds the account email).
        XCTAssertFalse(hash.contains("me@gmail.com"))
        XCTAssertNotEqual(hash, DraftFeedbackRecord.hashedIdentity("you@gmail.com|INBOX|10|42"))
    }

    func testDenyReasonCodesAreStableSnakeCase() {
        XCTAssertEqual(DenyReasonCode.notWorthReplying.rawValue, "not_worth_replying")
        XCTAssertEqual(DenyReasonCode.wrongTone.rawValue, "wrong_tone")
        XCTAssertEqual(DenyReasonCode.wrongContent.rawValue, "wrong_content")
        XCTAssertEqual(DenyReasonCode.handleLater.rawValue, "handle_later")
        XCTAssertEqual(DenyReasonCode.other.rawValue, "other")
        XCTAssertEqual(
            DenyReasonCode.presetsInDisplayOrder,
            [.notWorthReplying, .wrongTone, .wrongContent, .handleLater, .other]
        )
    }

    func testProvenanceCodesAreStable() {
        XCTAssertEqual(DraftFeedbackProvenance.watcher.rawValue, "watcher")
        XCTAssertEqual(DraftFeedbackProvenance.draftAnyway.rawValue, "draftAnyway")
        XCTAssertEqual(DraftFeedbackProvenance.authored.rawValue, "authored")
    }

    func testDenyReasonDropsOtherTextForNonOtherCode() {
        let reason = DenyReason(code: .wrongTone, otherText: "should be discarded")
        XCTAssertNil(reason.otherText)
    }

    func testDenyReasonTrimsAndNilsEmptyOtherText() {
        XCTAssertNil(DenyReason(code: .other, otherText: "   ").otherText)
        XCTAssertEqual(DenyReason(code: .other, otherText: "  spammy vendor ").otherText, "spammy vendor")
    }

    func testEncodedRecordHoldsOnlyCodesNumbersHashes() throws {
        // A record for an edited approval carries no free text at all.
        let record = DraftFeedbackRecord(
            outcome: .approvedAfterEdit,
            dispatch: .sent,
            editMagnitude: 0.25,
            denyReason: nil,
            provenance: .watcher,
            answeredNeedsInfo: true,
            draftIdentityHash: DraftFeedbackRecord.hashedIdentity("me@gmail.com|INBOX|10|42")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(record), encoding: .utf8) ?? ""
        // No account address, subject, sender, or body text ever appears.
        for forbidden in ["me@gmail.com", "@gmail", "INBOX", "Lunch", "Alice"] {
            XCTAssertFalse(json.contains(forbidden), "record leaked \(forbidden)")
        }
        XCTAssertTrue(json.contains("approvedAfterEdit"))
        XCTAssertTrue(json.contains("\"sent\""))
    }

    func testOnlyOtherFreeTextIsUserAuthored() throws {
        let record = DraftFeedbackRecord(
            outcome: .denied,
            denyReason: DenyReason(code: .other, otherText: "auto-notification from CI"),
            provenance: .watcher,
            answeredNeedsInfo: false,
            draftIdentityHash: DraftFeedbackRecord.hashedIdentity("me@gmail.com|INBOX|10|42")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(record), encoding: .utf8) ?? ""
        // The single permitted free text is present; nothing else user-derived is.
        XCTAssertTrue(json.contains("auto-notification from CI"))
        XCTAssertFalse(json.contains("me@gmail.com"))
    }
}
