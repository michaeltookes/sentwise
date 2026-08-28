import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateStaleThreadOverrideTests: XCTestCase {

    private func message(
        id: UInt32,
        subject: String,
        from: MailAddress = MailAddress(email: "alice@x.com"),
        inReplyTo: String? = nil,
        messageID: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 1,
            from: from,
            subject: subject,
            date: "",
            inReplyTo: inReplyTo,
            messageID: messageID
        )
    }

    private func result(_ messages: [MailMessage]) -> MailSearchResult {
        MailSearchResult(messages: messages, totalMatches: messages.count, offset: 0, hasMore: false)
    }

    private func makeAppState(provider: SearchStubMailProvider) -> AppState {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue,
            sendDelaySeconds: 0
        ))
        let llm = FakeLLMProvider(
            result: .success(()),
            completion: .success(LLMResponse(text: "Regenerated override."))
        )
        return AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
    }

    func testRegeneratePendingDraftPreservesOverrideRecoveryIdentity() async throws {
        let skippedSource = message(
            id: 5,
            subject: "Lunch?",
            from: MailAddress(email: "no-reply@x.com"),
            messageID: "<orig@x.com>"
        )
        let newerSource = message(
            id: 9,
            subject: "Re: Lunch?",
            inReplyTo: "<orig@x.com>",
            messageID: "<new@x.com>"
        )
        let provider = SearchStubMailProvider(threadResult: result([skippedSource, newerSource]))
        let appState = makeAppState(provider: provider)
        let persistence = try XCTUnwrap(appState.persistence as? AppStateMemoryPersistence)
        let entry = try appState.recordSkipSync(
            skippedSource,
            reason: .noReplySender,
            account: "me@gmail.com",
            mailbox: .inbox,
            preservesRecoveryWhenProcessed: true
        )
        persistence.skippedMessageSaveError = AppStatePersistenceError.writeDenied

        let failedRemoval = await appState.forceDraftSkippedMessage(entry)

        XCTAssertFalse(failedRemoval)
        let overrideDraft = try XCTUnwrap(appState.pendingDrafts.first)
        XCTAssertEqual(overrideDraft.replyWorthinessOverride, true)
        XCTAssertEqual(overrideDraft.replyWorthinessOverrideSource?.messageID, "<orig@x.com>")
        XCTAssertEqual(appState.skippedMessages, [entry])

        persistence.skippedMessageSaveError = nil
        appState.approvalError = nil
        await appState.approveDraft(overrideDraft)
        await appState.regeneratePendingDraft(overrideDraft)

        let replacement = try XCTUnwrap(appState.pendingDrafts.first)
        XCTAssertEqual(replacement.id, 9)
        XCTAssertEqual(replacement.sourceMessageID, "<new@x.com>")
        XCTAssertEqual(replacement.replyWorthinessOverride, true)
        XCTAssertEqual(replacement.replyWorthinessOverrideSource?.messageID, "<orig@x.com>")

        let retry = await appState.forceDraftSkippedMessage(entry)

        XCTAssertTrue(retry)
        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Regenerated override.")
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertTrue(persistence.skippedMessages.isEmpty)
    }
}
