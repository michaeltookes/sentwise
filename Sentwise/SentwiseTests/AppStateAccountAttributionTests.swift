import SentwiseMail
import XCTest
@testable import Sentwise

/// Account attribution + per-account status surfaced in Review Drafts, Activity,
/// and Settings (item 99).
@MainActor
final class AppStateAccountAttributionTests: XCTestCase {

    private func makeAppState(
        mailEmail: String,
        savedAccounts: [SavedMailAccount],
        pendingDrafts: [Draft] = [],
        skippedMessages: [SkippedMessage] = []
    ) -> AppState {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: mailEmail,
            savedAccounts: savedAccounts
        )
        return AppState(
            persistence: AppStateMemoryPersistence(
                settings: settings,
                pendingDrafts: pendingDrafts,
                skippedMessages: skippedMessages
            ),
            secrets: InMemorySecretStore(seed: [.mailAppPassword(email: mailEmail): "pw"]),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    func testAttributionHiddenForSingleAccount() {
        let app = makeAppState(
            mailEmail: "solo@x.com",
            savedAccounts: [SavedMailAccount(email: "solo@x.com", host: "imap.x.com", port: 993)]
        )
        XCTAssertFalse(app.showsAccountAttribution)
    }

    func testAttributionShownForMultipleAccounts() {
        let app = makeAppState(
            mailEmail: "one@x.com",
            savedAccounts: [
                SavedMailAccount(email: "one@x.com", host: "imap.x.com", port: 993),
                SavedMailAccount(email: "two@y.com", host: "imap.y.com", port: 993)
            ]
        )
        XCTAssertTrue(app.showsAccountAttribution)
        XCTAssertEqual(app.accountAttributionLabel(forEmail: "two@y.com"), "two@y.com")
        XCTAssertNil(app.accountAttributionLabel(forEmail: nil))
        XCTAssertNil(app.accountAttributionLabel(forEmail: "  "))
    }

    private func draft(account: String?) -> Draft {
        Draft(
            id: 3,
            sourceUIDValidity: 10,
            sourceAccountEmail: account,
            sourceMailbox: "INBOX",
            sourceSubject: "Lunch?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "body",
            replySubject: "Re: Lunch?",
            body: "reply",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func skipped(account: String) -> SkippedMessage {
        SkippedMessage(
            message: MailMessage(
                id: 4,
                uidValidity: 11,
                from: MailAddress(email: "no-reply@example.com"),
                subject: "Receipt",
                date: "",
                messageID: "<skip@example.com>"
            ),
            mailbox: .inbox,
            account: account,
            reason: .automatedNotification
        )
    }

    func testDraftRowAccountBadgeHiddenForSingleAccount() {
        let app = makeAppState(
            mailEmail: "solo@x.com",
            savedAccounts: [SavedMailAccount(email: "solo@x.com", host: "imap.x.com", port: 993)]
        )
        // No badge for single-account users, even for a tagged draft.
        XCTAssertNil(app.draftRowAccountBadge(for: draft(account: "solo@x.com")))
    }

    func testDraftRowAccountBadgeShownWhenMultipleAndTagged() {
        let app = makeAppState(
            mailEmail: "one@x.com",
            savedAccounts: [
                SavedMailAccount(email: "one@x.com", host: "imap.x.com", port: 993),
                SavedMailAccount(email: "two@y.com", host: "imap.y.com", port: 993)
            ]
        )
        XCTAssertEqual(app.draftRowAccountBadge(for: draft(account: "two@y.com")), "two@y.com")
        // A legacy untagged draft shows no badge even in multi-account mode.
        XCTAssertNil(app.draftRowAccountBadge(for: draft(account: nil)))
    }

    func testAttributionMailboxesUnionsSavedConnectedAndFocusedSorted() {
        let app = makeAppState(
            mailEmail: "one@x.com",
            savedAccounts: [
                SavedMailAccount(email: "one@x.com", host: "imap.x.com", port: 993),
                SavedMailAccount(email: "two@y.com", host: "imap.y.com", port: 993)
            ]
        )
        app.isAccountConnected = true
        app.backgroundConnectedAccounts = [
            ConnectedMailAccount(email: "three@z.com", host: "imap.z.com", port: 993, appPassword: "pw3")
        ]
        // Saved + connected + focused, normalized, de-duplicated, sorted.
        XCTAssertEqual(app.attributionMailboxes, ["one@x.com", "three@z.com", "two@y.com"])
    }

    func testAttributionMailboxesIncludeRetainedDraftSources() {
        let removedDraft = draft(account: "removed@y.com")
        let app = makeAppState(
            mailEmail: "one@x.com",
            savedAccounts: [SavedMailAccount(email: "one@x.com", host: "imap.x.com", port: 993)],
            pendingDrafts: [removedDraft]
        )

        XCTAssertTrue(app.showsAccountAttribution)
        XCTAssertEqual(app.attributionMailboxes, ["one@x.com", "removed@y.com"])
        XCTAssertEqual(app.draftRowAccountBadge(for: removedDraft), "removed@y.com")
    }

    func testAttributionMailboxesIncludeRetainedSkippedSources() {
        let app = makeAppState(
            mailEmail: "one@x.com",
            savedAccounts: [SavedMailAccount(email: "one@x.com", host: "imap.x.com", port: 993)],
            skippedMessages: [skipped(account: "removed@y.com")]
        )

        XCTAssertTrue(app.showsAccountAttribution)
        XCTAssertEqual(app.attributionMailboxes, ["one@x.com", "removed@y.com"])
    }

    func testAttributionMailboxesIncludeInMemorySkippedSources() {
        let app = makeAppState(
            mailEmail: "one@x.com",
            savedAccounts: [SavedMailAccount(email: "one@x.com", host: "imap.x.com", port: 993)]
        )
        app.skippedMessages = [skipped(account: "removed@y.com")]

        XCTAssertTrue(app.showsAccountAttribution)
        XCTAssertEqual(app.attributionMailboxes, ["one@x.com", "removed@y.com"])
    }

    func testPerAccountWatchStatusAndHealth() {
        let app = makeAppState(
            mailEmail: "one@x.com",
            savedAccounts: [SavedMailAccount(email: "one@x.com", host: "imap.x.com", port: 993)]
        )
        let background = ConnectedMailAccount(
            email: "two@y.com", host: "imap.y.com", port: 993, appPassword: "pw2"
        )
        background.watchStatus = .paused
        background.watchError = "Authentication failed."
        app.backgroundConnectedAccounts = [background]
        app.watchStatus = .watching

        XCTAssertEqual(app.watchStatus(forAccountEmail: "one@x.com"), .watching)
        XCTAssertEqual(app.watchStatus(forAccountEmail: "two@y.com"), .paused)
        XCTAssertNil(app.watchError(forAccountEmail: "one@x.com"))
        XCTAssertEqual(app.watchError(forAccountEmail: "two@y.com"), "Authentication failed.")
    }
}
