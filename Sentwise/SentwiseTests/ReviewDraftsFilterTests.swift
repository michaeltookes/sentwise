import SentwiseMail
import XCTest
@testable import Sentwise

/// Verifies the pure search/filter helpers behind the Review Drafts search field
/// (item 76): case-insensitive matching against sender name, sender address, and
/// the MIME-decoded subject (item 69) for both `Draft` and `SkippedMessage`, an
/// empty query matching everything, authored follow-ups matching on their label
/// and `replySubject`, and the "N of M" tab-badge logic.
final class ReviewDraftsFilterTests: XCTestCase {

    // MARK: - Fixtures

    /// A Q-encoded RFC 2047 subject. Raw it reads "=?UTF-8?Q?Caf=C3=A9_time?=";
    /// `MIMEEncodedWord.displaySubject` decodes it to "Café time". Matching on
    /// "café" therefore only succeeds if the filter decodes rather than searching
    /// the raw encoded-word header.
    private let encodedSubject = "=?UTF-8?Q?Caf=C3=A9_time?="
    private let decodedSubject = "Café time"

    private func draft(
        subject: String,
        from: MailAddress? = MailAddress(name: "Alice Example", email: "alice@example.com"),
        replySubject: String = "Re: subject",
        authoredRecipients: [MailAddress]? = nil
    ) -> Draft {
        Draft(
            id: 1,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: "INBOX",
            sourceSubject: subject,
            sourceFrom: from,
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "body",
            replySubject: replySubject,
            body: "reply body",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            authoredRecipients: authoredRecipients
        )
    }

    private func skipped(
        subject: String,
        from: MailAddress? = MailAddress(name: "Bob Sender", email: "bob@work.co")
    ) -> SkippedMessage {
        let message = MailMessage(
            id: 5,
            uidValidity: 7,
            from: from,
            subject: subject,
            date: "",
            messageID: "<5@work.co>"
        )
        return SkippedMessage(
            message: message,
            mailbox: .inbox,
            account: "me@gmail.com",
            reason: .bulkOrListMail
        )
    }

    // MARK: - Draft matching

    func testDraftMatchesBySenderName() {
        XCTAssertTrue(ReviewDraftsFilter.matches(draft(subject: "Lunch?"), query: "alice"))
    }

    func testDraftMatchesBySenderEmail() {
        XCTAssertTrue(ReviewDraftsFilter.matches(draft(subject: "Lunch?"), query: "example.com"))
    }

    func testDraftMatchesByDecodedSubjectNotRawHeader() {
        let subject = draft(subject: encodedSubject)
        // Matches the decoded form ...
        XCTAssertTrue(ReviewDraftsFilter.matches(subject, query: "café"))
        XCTAssertTrue(ReviewDraftsFilter.matches(subject, query: "time"))
        // ... and does NOT match the raw encoded-word artifact.
        XCTAssertFalse(ReviewDraftsFilter.matches(subject, query: "c3"))
        XCTAssertFalse(ReviewDraftsFilter.matches(subject, query: "utf-8"))
    }

    func testDraftMatchIsCaseInsensitive() {
        let subject = draft(subject: "Quarterly Report")
        XCTAssertTrue(ReviewDraftsFilter.matches(subject, query: "QUARTERLY"))
        XCTAssertTrue(ReviewDraftsFilter.matches(subject, query: "ALICE EXAMPLE"))
    }

    func testDraftEmptyQueryMatchesEverything() {
        let subject = draft(subject: "Anything")
        XCTAssertTrue(ReviewDraftsFilter.matches(subject, query: ""))
        XCTAssertTrue(ReviewDraftsFilter.matches(subject, query: "   "))
    }

    func testDraftNonMatchReturnsFalse() {
        XCTAssertFalse(ReviewDraftsFilter.matches(draft(subject: "Lunch?"), query: "zzzznope"))
    }

    func testAuthoredFollowUpMatchesLabelAndReplySubject() {
        let followUp = draft(
            subject: "",
            from: nil,
            replySubject: "Next steps after our call",
            authoredRecipients: [MailAddress(name: nil, email: "lead@client.com")]
        )
        // No inbound sender: matches the announced label ...
        XCTAssertTrue(ReviewDraftsFilter.matches(followUp, query: "post-call"))
        // ... and the user-written subject.
        XCTAssertTrue(ReviewDraftsFilter.matches(followUp, query: "next steps"))
        XCTAssertFalse(ReviewDraftsFilter.matches(followUp, query: "alice"))
    }

    // MARK: - SkippedMessage matching

    func testSkippedMatchesBySenderName() {
        XCTAssertTrue(ReviewDraftsFilter.matches(skipped(subject: "Newsletter"), query: "bob"))
    }

    func testSkippedMatchesBySenderEmail() {
        XCTAssertTrue(ReviewDraftsFilter.matches(skipped(subject: "Newsletter"), query: "work.co"))
    }

    func testSkippedMatchesByDecodedSubjectNotRawHeader() {
        let entry = skipped(subject: encodedSubject)
        XCTAssertTrue(ReviewDraftsFilter.matches(entry, query: "café"))
        XCTAssertFalse(ReviewDraftsFilter.matches(entry, query: "=?utf-8?"))
    }

    func testSkippedMatchIsCaseInsensitive() {
        XCTAssertTrue(ReviewDraftsFilter.matches(skipped(subject: "Receipt"), query: "RECEIPT"))
    }

    func testSkippedEmptyQueryMatchesEverything() {
        XCTAssertTrue(ReviewDraftsFilter.matches(skipped(subject: "x"), query: ""))
        XCTAssertTrue(ReviewDraftsFilter.matches(skipped(subject: "x"), query: "  "))
    }

    func testSkippedNonMatchReturnsFalse() {
        XCTAssertFalse(ReviewDraftsFilter.matches(skipped(subject: "Receipt"), query: "zzzznope"))
    }

    // MARK: - Decoded-subject helper sanity

    func testSearchableTextDecodesSubject() {
        XCTAssertTrue(ReviewDraftsFilter.searchableText(for: draft(subject: encodedSubject)).contains(decodedSubject))
        XCTAssertTrue(ReviewDraftsFilter.searchableText(for: skipped(subject: encodedSubject)).contains(decodedSubject))
    }

    // MARK: - Count label ("N of M")

    func testCountLabelNotFilteringShowsTotal() {
        XCTAssertEqual(ReviewDraftsFilter.countLabel(filtered: 3, total: 3, isFiltering: false), "3")
    }

    func testCountLabelFilteringShowsNofM() {
        XCTAssertEqual(ReviewDraftsFilter.countLabel(filtered: 1, total: 4, isFiltering: true), "1 of 4")
    }

    func testCountLabelFilteringWithNoMatchesShowsZeroOfM() {
        XCTAssertEqual(ReviewDraftsFilter.countLabel(filtered: 0, total: 4, isFiltering: true), "0 of 4")
    }

    func testCountLabelZeroTotalHasNoBadge() {
        XCTAssertNil(ReviewDraftsFilter.countLabel(filtered: 0, total: 0, isFiltering: false))
        XCTAssertNil(ReviewDraftsFilter.countLabel(filtered: 0, total: 0, isFiltering: true))
    }

    // MARK: - Account scope (item 102)

    private func draft(subject: String, account: String?) -> Draft {
        Draft(
            id: 2,
            sourceUIDValidity: 10,
            sourceAccountEmail: account,
            sourceMailbox: "INBOX",
            sourceSubject: subject,
            sourceFrom: MailAddress(name: "Alice Example", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "body",
            replySubject: "Re: subject",
            body: "reply body",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func skipped(subject: String, account: String) -> SkippedMessage {
        let message = MailMessage(
            id: 6, uidValidity: 7,
            from: MailAddress(name: "Bob", email: "bob@work.co"),
            subject: subject, date: "", messageID: "<6@work.co>"
        )
        return SkippedMessage(message: message, mailbox: .inbox, account: account, reason: .bulkOrListMail)
    }

    func testAccountScopeAllMatchesEveryMailbox() {
        let scope = ReviewDraftsFilter.AccountScope.all
        XCTAssertTrue(scope.matches(accountEmail: "me@gmail.com"))
        XCTAssertTrue(scope.matches(accountEmail: "other@work.com"))
        XCTAssertTrue(scope.matches(accountEmail: nil))
        XCTAssertFalse(scope.isFiltering)
        XCTAssertNil(scope.mailbox)
    }

    func testAccountScopeMailboxMatchesOnlyThatMailbox() {
        let scope = ReviewDraftsFilter.AccountScope.mailbox("me@gmail.com")
        XCTAssertTrue(scope.matches(accountEmail: "me@gmail.com"))
        // Casing/whitespace is normalized on both sides.
        XCTAssertTrue(scope.matches(accountEmail: "  ME@Gmail.com "))
        XCTAssertFalse(scope.matches(accountEmail: "other@work.com"))
        XCTAssertTrue(scope.isFiltering)
        XCTAssertEqual(scope.mailbox, "me@gmail.com")
    }

    func testLegacyUntaggedItemsAppearOnlyUnderAllMailboxes() {
        let scope = ReviewDraftsFilter.AccountScope.mailbox("me@gmail.com")
        // A legacy draft with no source account is never attributed to a guess.
        XCTAssertFalse(scope.matches(accountEmail: nil))
        XCTAssertFalse(scope.matches(accountEmail: ""))
        XCTAssertTrue(ReviewDraftsFilter.AccountScope.all.matches(accountEmail: nil))
    }

    func testAccountScopeInitFromPickerTag() {
        XCTAssertEqual(ReviewDraftsFilter.AccountScope(mailbox: nil), .all)
        XCTAssertEqual(ReviewDraftsFilter.AccountScope(mailbox: "  "), .all)
        XCTAssertEqual(ReviewDraftsFilter.AccountScope(mailbox: "Me@Gmail.com"), .mailbox("me@gmail.com"))
    }

    func testAccountAccessorsNormalizeAndTreatBlankAsUntagged() {
        XCTAssertEqual(ReviewDraftsFilter.accountEmail(for: draft(subject: "x", account: "Me@Gmail.com")), "me@gmail.com")
        XCTAssertNil(ReviewDraftsFilter.accountEmail(for: draft(subject: "x", account: nil)))
        XCTAssertNil(ReviewDraftsFilter.accountEmail(for: draft(subject: "x", account: "  ")))
        XCTAssertEqual(ReviewDraftsFilter.accountEmail(for: skipped(subject: "x", account: "Side@Work.com")), "side@work.com")
    }

    func testAccountAndSearchCompose() {
        let mine = draft(subject: "Quarterly report", account: "me@gmail.com")
        let theirs = draft(subject: "Quarterly report", account: "side@work.com")
        let scope = ReviewDraftsFilter.AccountScope.mailbox("me@gmail.com")
        // Same subject, different mailbox: the account scope excludes the other.
        XCTAssertTrue(ReviewDraftsFilter.matches(mine, query: "quarterly", account: scope))
        XCTAssertFalse(ReviewDraftsFilter.matches(theirs, query: "quarterly", account: scope))
        // A non-matching query still excludes even the in-scope mailbox.
        XCTAssertFalse(ReviewDraftsFilter.matches(mine, query: "zzznope", account: scope))
        // Under .all, both mailboxes pass the (matching) query.
        XCTAssertTrue(ReviewDraftsFilter.matches(theirs, query: "quarterly", account: .all))
    }

    func testAccountAndSearchComposeForSkipped() {
        let mine = skipped(subject: "Newsletter", account: "me@gmail.com")
        let theirs = skipped(subject: "Newsletter", account: "side@work.com")
        let scope = ReviewDraftsFilter.AccountScope.mailbox("me@gmail.com")
        XCTAssertTrue(ReviewDraftsFilter.matches(mine, query: "news", account: scope))
        XCTAssertFalse(ReviewDraftsFilter.matches(theirs, query: "news", account: scope))
        XCTAssertTrue(ReviewDraftsFilter.matches(theirs, query: "news", account: .all))
    }

    // MARK: - No-matches copy (item 76/102)

    func testNoMatchesDetailPhrasingBySearchAndAccount() {
        XCTAssertEqual(
            PendingDraftsView.noMatchesDetail(searchQuery: "lunch", mailbox: nil, noun: "drafts"),
            "No drafts match “lunch”."
        )
        XCTAssertEqual(
            PendingDraftsView.noMatchesDetail(searchQuery: "lunch", mailbox: "me@gmail.com", noun: "drafts"),
            "No drafts in me@gmail.com match “lunch”."
        )
        XCTAssertEqual(
            PendingDraftsView.noMatchesDetail(searchQuery: "  ", mailbox: "me@gmail.com", noun: "skipped messages"),
            "No skipped messages in me@gmail.com."
        )
        XCTAssertEqual(
            PendingDraftsView.noMatchesDetail(searchQuery: "", mailbox: nil, noun: "drafts"),
            "No drafts match your filter."
        )
    }
}
