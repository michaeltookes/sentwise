import SentwiseMail
import XCTest
@testable import Sentwise

/// Regression coverage for "Draft anyway" override deduplication.
@MainActor
final class AppStateReplyWorthinessOverrideTests: XCTestCase {

    private func message(id: UInt32, uidValidity: UInt32? = nil, from: String = "alice@x.com") -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: uidValidity,
            from: MailAddress(name: "Alice", email: from),
            replyTo: nil,
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

    private func makeAppState() -> (AppState, FakeAppMailProvider, AppStateMemoryPersistence) {
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
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: .success([]),
            bodyResult: .success(Data("Please advise.".utf8)),
            headerResult: .success(MailHeaderFields())
        )
        let llm = FakeLLMProvider(
            result: .success(()),
            completion: .success(LLMResponse(text: "On it."))
        )
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        return (appState, provider, persistence)
    }

    func testForceDraftRetryMatchesExistingOverrideAcrossAccountCasing() async throws {
        let (appState, provider, persistence) = makeAppState()
        let source = message(id: 11, uidValidity: 7, from: "no-reply@x.com")
        let entry = try appState.recordSkipSync(
            source,
            reason: .noReplySender,
            account: "me@gmail.com",
            mailbox: .inbox,
            preservesRecoveryWhenProcessed: true
        )
        appState.mailEmail = "Me@Gmail.com"
        persistence.skippedMessageSaveError = AppStatePersistenceError.writeDenied

        let failedRemoval = await appState.forceDraftSkippedMessage(entry)

        XCTAssertFalse(failedRemoval)
        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(appState.pendingDrafts.first?.sourceAccountEmail, "Me@Gmail.com")
        XCTAssertEqual(appState.pendingDrafts.first?.replyWorthinessOverrideSource?.account, "Me@Gmail.com")
        XCTAssertEqual(appState.pendingDrafts.first?.replyWorthinessOverrideSource?.mailbox, Mailbox.inbox.imapName)
        XCTAssertEqual(appState.pendingDrafts.first?.replyWorthinessOverrideSource?.id, 11)
        XCTAssertEqual(appState.pendingDrafts.first?.replyWorthinessOverrideSource?.uidValidity, 7)
        XCTAssertEqual(appState.pendingDrafts.first?.replyWorthinessOverrideSource?.messageID, "<11@x.com>")
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
        XCTAssertEqual(appState.skippedMessages, [entry])

        appState.mailEmail = "me@gmail.com"
        persistence.skippedMessageSaveError = nil
        appState.approvalError = nil

        let retry = await appState.forceDraftSkippedMessage(entry)

        XCTAssertTrue(retry)
        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertTrue(persistence.skippedMessages.isEmpty)
        XCTAssertNil(appState.approvalError)
    }
}
