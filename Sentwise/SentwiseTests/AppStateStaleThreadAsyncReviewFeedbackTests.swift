import SentwiseMail
import Foundation
import XCTest
@testable import Sentwise

final class SuspendedThreadSearchMailProvider: MailProvider, @unchecked Sendable {
    let didStartThreadSearch = XCTestExpectation(description: "thread search started")
    var threadResult: Result<MailSearchResult, Error>
    var sentResult: MailSearchResult = .empty(offset: 0)
    var bodyResult: Result<Data, MailError> = .success(Data("Please approve the budget.".utf8))
    private let lock = NSLock()
    private var threadContinuation: CheckedContinuation<MailSearchResult, Error>?
    private(set) var bodyFetchCount = 0
    private(set) var sendCount = 0
    private(set) var appendCount = 0

    init(threadResult: Result<MailSearchResult, Error>) {
        self.threadResult = threadResult
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] { [] }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        bodyFetchCount += 1
        return try bodyResult.get()
    }

    func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult {
        if !criteria.headers.isEmpty {
            return .empty(offset: offset)
        }
        if mailbox == .sent {
            return sentResult
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            threadContinuation = continuation
            lock.unlock()
            didStartThreadSearch.fulfill()
        }
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws { appendCount += 1 }

    func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws { sendCount += 1 }

    func completeThreadSearch() {
        lock.lock()
        let continuation = threadContinuation
        threadContinuation = nil
        lock.unlock()
        continuation?.resume(with: threadResult)
    }
}

@MainActor
final class AppStateAsyncReviewFeedbackTests: XCTestCase {
    private let accountChangedMessage = "The email account changed before this action finished. "
        + "Try again with the current account."

    private func draft(id: UInt32 = 5, subject: String = "Lunch?") -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 1,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: subject,
            sourceFrom: MailAddress(name: "Alice", email: "alice@x.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@x.com>",
            replySubject: "Re: \(subject)",
            body: "Sounds good!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func message(
        id: UInt32,
        subject: String,
        inReplyTo: String? = nil,
        messageID: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 1,
            from: MailAddress(email: "alice@x.com"),
            to: [],
            subject: subject,
            date: "",
            inReplyTo: inReplyTo,
            messageID: messageID
        )
    }

    private func result(_ messages: [MailMessage]) -> MailSearchResult {
        MailSearchResult(messages: messages, totalMatches: messages.count, offset: 0, hasMore: false)
    }

    private func makeAppState(
        provider: MailProvider,
        llmText: String = "Fresh reply."
    ) -> AppState {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue,
            sendDelaySeconds: 0
        ))
        let llm = FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: llmText)))
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "app-pw"
        return appState
    }

    private func switchAccount(_ appState: AppState) {
        appState.mailEmail = "other@gmail.com"
        appState.mailAppPassword = "other-pw"
    }

    func testApproveDraftDoesNotDispatchAfterAccountChangesDuringStaleLookup() async {
        let staleDraft = draft()
        let provider = SuspendedThreadSearchMailProvider(threadResult: .success(result([
            message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>")
        ])))
        let appState = makeAppState(provider: provider)
        appState.pendingDrafts = [staleDraft]

        let approval = Task { await appState.approveDraft(staleDraft) }
        await fulfillment(of: [provider.didStartThreadSearch], timeout: 1)
        switchAccount(appState)
        provider.completeThreadSearch()
        await approval.value

        XCTAssertEqual(provider.sendCount, 0)
        XCTAssertEqual(provider.appendCount, 0)
        XCTAssertEqual(appState.pendingDrafts, [staleDraft])
        XCTAssertEqual(appState.approvalError, accountChangedMessage)
        XCTAssertNil(appState.pendingStaleWarnings[staleDraft.identity])
    }

    func testApproveDraftPreviewDoesNotDispatchAfterAccountChangesDuringStaleLookup() async {
        let previewDraft = draft()
        let provider = SuspendedThreadSearchMailProvider(threadResult: .success(result([
            message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>")
        ])))
        let appState = makeAppState(provider: provider)
        appState.generatedDraft = previewDraft

        let approval = Task { try await appState.approveDraftPreview(previewDraft) }
        await fulfillment(of: [provider.didStartThreadSearch], timeout: 1)
        switchAccount(appState)
        provider.completeThreadSearch()

        do {
            _ = try await approval.value
            XCTFail("expected account-changed rejection")
        } catch let error as DraftDispatchError {
            XCTAssertEqual(error, .accountChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(provider.sendCount, 0)
        XCTAssertEqual(provider.appendCount, 0)
    }

    func testApproveDraftKeepsOriginalSendBehaviorWhenSettingChangesDuringStaleLookup() async {
        let pendingDraft = draft()
        let provider = SuspendedThreadSearchMailProvider(threadResult: .success(result([
            message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>")
        ])))
        let appState = makeAppState(provider: provider)
        appState.sendBehavior = .saveAsDraft
        appState.pendingDrafts = [pendingDraft]

        let approval = Task { await appState.approveDraft(pendingDraft) }
        await fulfillment(of: [provider.didStartThreadSearch], timeout: 1)
        appState.sendBehavior = .autoSend
        provider.completeThreadSearch()
        await approval.value

        XCTAssertEqual(provider.sendCount, 0)
        XCTAssertEqual(provider.appendCount, 1)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    func testApproveDraftPreviewKeepsOriginalSendBehaviorWhenSettingChangesDuringStaleLookup() async throws {
        let previewDraft = draft()
        let provider = SuspendedThreadSearchMailProvider(threadResult: .success(result([
            message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>")
        ])))
        let appState = makeAppState(provider: provider)
        appState.sendBehavior = .saveAsDraft
        appState.generatedDraft = previewDraft

        let approval = Task { try await appState.approveDraftPreview(previewDraft) }
        await fulfillment(of: [provider.didStartThreadSearch], timeout: 1)
        appState.sendBehavior = .autoSend
        provider.completeThreadSearch()
        let confirmation = try await approval.value

        XCTAssertEqual(confirmation, "Saved to your Drafts.")
        XCTAssertEqual(provider.sendCount, 0)
        XCTAssertEqual(provider.appendCount, 1)
    }

    func testRegeneratePendingDraftDoesNotFetchReplacementAfterAccountChangesDuringSourceLookup() async {
        let staleDraft = draft()
        let provider = SuspendedThreadSearchMailProvider(threadResult: .success(result([
            message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>"),
            message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>")
        ])))
        let appState = makeAppState(provider: provider, llmText: "Regenerated reply.")
        appState.pendingDrafts = [staleDraft]

        let regeneration = Task { await appState.regeneratePendingDraft(staleDraft) }
        await fulfillment(of: [provider.didStartThreadSearch], timeout: 1)
        switchAccount(appState)
        provider.completeThreadSearch()
        await regeneration.value

        XCTAssertEqual(provider.bodyFetchCount, 0)
        XCTAssertEqual(appState.pendingDrafts, [staleDraft])
        XCTAssertEqual(appState.approvalError, accountChangedMessage)
    }

    func testRegenerateDraftPreviewDoesNotReplaceAfterAccountChangesDuringDraftGeneration() async {
        let staleDraft = draft()
        let provider = SearchStubMailProvider(
            threadResult: result([
                message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>"),
                message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>")
            ])
        )
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue,
            sendDelaySeconds: 0
        ))
        let llm = SuspendedLLMProvider()
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.mailAppPassword = "app-pw"
        appState.generatedDraft = staleDraft

        let regeneration = Task { try await appState.regenerateDraftPreview(staleDraft) }
        await fulfillment(of: [llm.didStartCompletion], timeout: 1)
        switchAccount(appState)
        llm.completeDraft(with: .success(LLMResponse(text: "Late regenerated preview.")))

        do {
            _ = try await regeneration.value
            XCTFail("expected account-changed rejection")
        } catch let error as DraftDispatchError {
            XCTAssertEqual(error, .accountChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(appState.generatedDraft, staleDraft)
    }

    func testRegenerateDraftPreviewReplacesDisplayedDraftWithNewestRelatedMessage() async throws {
        let staleDraft = draft()
        let provider = SearchStubMailProvider(
            threadResult: result([
                message(id: 5, subject: "Lunch?", messageID: "<orig@x.com>"),
                message(id: 9, subject: "Re: Lunch?", inReplyTo: "<orig@x.com>", messageID: "<new@x.com>")
            ])
        )
        let appState = makeAppState(provider: provider, llmText: "Regenerated preview reply.")
        appState.generatedDraft = staleDraft

        let replacement = try await appState.regenerateDraftPreview(staleDraft)

        XCTAssertEqual(replacement.id, 9)
        XCTAssertEqual(replacement.sourceMessageID, "<new@x.com>")
        XCTAssertEqual(replacement.generatedAt, staleDraft.generatedAt)
        XCTAssertNotNil(replacement.regeneratedAt)
        XCTAssertEqual(replacement.body, "Regenerated preview reply.")
        XCTAssertEqual(appState.generatedDraft, replacement)
        XCTAssertEqual(provider.lastBodyUID, 9)
        XCTAssertEqual(provider.lastExpectedUIDValidity, 1)
    }
}
