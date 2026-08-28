import SentwiseMail
import XCTest
@testable import Sentwise

/// Verifies the pure status-chip derivation for the collapsed Drafts list rows
/// (item 82): needs-info drafts and empty-bodied model-declined drafts read as
/// "Needs info", authored follow-ups without recipients read as "Add
/// recipients", and an ordinary reply reads as "Ready".
final class PendingDraftRowStatusTests: XCTestCase {

    private func draft(
        body: String = "Thursday works!",
        needsInfo: DraftNeedsInfo? = nil,
        notReplyWorthy: DraftNotReplyWorthy? = nil,
        authoredRecipients: [MailAddress]? = nil
    ) -> Draft {
        Draft(
            id: 1,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: "INBOX",
            sourceSubject: "Lunch?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: Lunch?",
            body: body,
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            needsInfo: needsInfo,
            notReplyWorthy: notReplyWorthy,
            authoredRecipients: authoredRecipients
        )
    }

    func testPlainReplyIsReady() {
        XCTAssertEqual(PendingDraftRowStatus.status(for: draft()), .ready)
    }

    func testNeedsInfoDraftIsNeedsInfo() {
        let subject = draft(needsInfo: DraftNeedsInfo(summary: "Need the order number."))
        XCTAssertEqual(PendingDraftRowStatus.status(for: subject), .needsInfo)
    }

    func testNotReplyWorthyWithEmptyBodyIsNeedsInfo() {
        let subject = draft(body: "   ", notReplyWorthy: DraftNotReplyWorthy(summary: "No reply needed."))
        XCTAssertEqual(PendingDraftRowStatus.status(for: subject), .needsInfo)
    }

    func testNotReplyWorthyWithUserWrittenBodyIsReady() {
        let subject = draft(body: "Actually, here is my reply.", notReplyWorthy: DraftNotReplyWorthy(summary: "No reply needed."))
        XCTAssertEqual(PendingDraftRowStatus.status(for: subject), .ready)
    }

    func testAuthoredFollowUpWithoutRecipientsIsAddRecipients() {
        let subject = draft(authoredRecipients: [])
        XCTAssertEqual(PendingDraftRowStatus.status(for: subject), .addRecipients)
    }

    func testAuthoredFollowUpWithRecipientsIsReady() {
        let subject = draft(authoredRecipients: [MailAddress(name: nil, email: "lead@example.com")])
        XCTAssertEqual(PendingDraftRowStatus.status(for: subject), .ready)
    }

    func testNeedsInfoTakesPrecedenceOverMissingRecipients() {
        let subject = draft(
            needsInfo: DraftNeedsInfo(summary: "Need more."),
            authoredRecipients: []
        )
        XCTAssertEqual(PendingDraftRowStatus.status(for: subject), .needsInfo)
    }
}
