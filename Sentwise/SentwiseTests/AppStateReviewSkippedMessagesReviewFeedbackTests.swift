import SentwiseMail
import XCTest
@testable import Sentwise

/// Regression coverage for PR review feedback around the all-mailbox skipped
/// review list and filtered Clear behavior.
@MainActor
final class ReviewSkippedMessagesTests: XCTestCase {

    private func message(id: UInt32, from: String) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 7,
            from: MailAddress(name: "Alice", email: from),
            subject: "Subject \(id)",
            date: "",
            messageID: "<\(id)@x.com>"
        )
    }

    private func baselineProcessed() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        return processed
    }

    private func makeAppState(
        skippedMessages: [SkippedMessage] = []
    ) -> (AppState, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6"
            ),
            processedMessages: baselineProcessed(),
            skippedMessages: skippedMessages
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        return (appState, persistence)
    }

    func testReviewSkippedMessagesIncludesInMemoryEntryAfterPersistenceFailure() throws {
        let (appState, persistence) = makeAppState()
        persistence.skippedMessageSaveError = AppStatePersistenceError.writeDenied

        appState.recordSkip(
            message(id: 14, from: "no-reply@x.com"),
            reason: .noReplySender,
            account: "me@gmail.com",
            mailbox: .inbox
        )

        let entry = try XCTUnwrap(appState.skippedMessages.first)
        XCTAssertTrue(persistence.skippedMessages.isEmpty)
        XCTAssertEqual(appState.reviewSkippedMessages, [entry])
    }

    func testSuccessfulRecordPersistsPreviouslyCachedReviewSkippedMessages() throws {
        let (appState, persistence) = makeAppState()
        persistence.skippedMessageSaveError = AppStatePersistenceError.writeDenied
        appState.recordSkip(
            message(id: 20, from: "alerts@x.com"),
            reason: .automatedNotification,
            account: "side-a@work.com",
            mailbox: .inbox
        )
        appState.recordSkip(
            message(id: 21, from: "notifications@x.com"),
            reason: .bulkOrListMail,
            account: "side-b@work.com",
            mailbox: .inbox
        )
        let latestCached = try XCTUnwrap(appState.reviewSkippedMessages.first { $0.account == "side-b@work.com" })
        let retained = try XCTUnwrap(appState.reviewSkippedMessages.first { $0.account == "side-a@work.com" })
        XCTAssertTrue(persistence.skippedMessages.isEmpty)

        persistence.skippedMessageSaveError = nil
        let durable = try appState.recordSkipSync(
            message(id: 22, from: "no-reply@x.com"),
            reason: .noReplySender,
            account: "me@gmail.com",
            mailbox: .inbox
        )

        XCTAssertEqual(persistence.skippedMessages.map(\.id), [durable.id, latestCached.id, retained.id])
        XCTAssertTrue(persistence.skippedMessages.contains(retained))
        XCTAssertTrue(appState.reviewSkippedMessages.contains(retained))
    }

    func testDismissReviewSkippedMessagesOnlyClearsProvidedFilteredRows() throws {
        let (appState, persistence) = makeAppState()
        let focused = try appState.recordSkipSync(
            message(id: 15, from: "no-reply@x.com"),
            reason: .noReplySender,
            account: "me@gmail.com",
            mailbox: .inbox,
            preservesRecoveryWhenProcessed: true
        )
        let background = try appState.recordSkipSync(
            message(id: 16, from: "notifications@x.com"),
            reason: .automatedNotification,
            account: "side@work.com",
            mailbox: .inbox,
            preservesRecoveryWhenProcessed: true
        )
        let filtered = appState.reviewSkippedMessages.filter {
            ReviewDraftsFilter.matches($0, query: "", account: .mailbox("me@gmail.com"))
        }
        XCTAssertEqual(filtered, [focused])

        appState.dismissReviewSkippedMessages(filtered)

        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertEqual(persistence.skippedMessages, [background])
        XCTAssertEqual(appState.reviewSkippedMessages, [background])
        XCTAssertFalse(appState.hasSkippedMessage(focused.message, account: focused.account, mailbox: focused.mailbox))
        XCTAssertTrue(appState.hasSkippedMessage(
            background.message,
            account: background.account,
            mailbox: background.mailbox
        ))
    }

    func testReviewSkippedMessagesUsesRestoredCache() throws {
        let retained = SkippedMessage(
            message: message(id: 17, from: "alerts@x.com"),
            mailbox: .inbox,
            account: "me@gmail.com",
            reason: .automatedNotification
        )
        let replacement = SkippedMessage(
            message: message(id: 18, from: "other@x.com"),
            mailbox: .inbox,
            account: "side@work.com",
            reason: .bulkOrListMail
        )
        let (appState, persistence) = makeAppState(skippedMessages: [retained])
        XCTAssertEqual(appState.reviewSkippedMessages, [retained])

        try persistence.saveSkippedMessagesSync([replacement])

        XCTAssertEqual(appState.reviewSkippedMessages, [retained])
    }

    func testSkippedMessageRowIncludesMailboxIdentity() {
        let entry = SkippedMessage(
            message: message(id: 19, from: "alerts@x.com"),
            mailbox: .inbox,
            account: "side@work.com",
            reason: .automatedNotification
        )
        let row = SkippedMessageRow(entry: entry, selection: ReviewWindowSelection())

        XCTAssertEqual(row.mailboxBadgeText, "side@work.com")
        XCTAssertEqual(
            row.accessibilityLabelText,
            "Skipped message from Alice, mailbox side@work.com, Automated notification, Subject 19"
        )
    }
}
