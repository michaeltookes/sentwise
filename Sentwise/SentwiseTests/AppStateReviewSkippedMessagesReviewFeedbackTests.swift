import SentwiseMail
import XCTest
@testable import Sentwise

/// Regression coverage for PR review feedback around the all-mailbox skipped
/// review list and filtered Clear behavior.
@MainActor
final class AppStateReviewSkippedMessagesReviewFeedbackTests: XCTestCase {

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

    private func makeAppState() -> (AppState, AppStateMemoryPersistence) {
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
            processedMessages: baselineProcessed()
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
}
