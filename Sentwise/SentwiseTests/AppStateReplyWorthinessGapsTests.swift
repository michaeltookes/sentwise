import SentwiseMail
import XCTest
@testable import Sentwise

/// Tests the reply-worthiness gaps closed for transactional mail (item 66:
/// both-address evaluation + transactional sender tokens) and the LLM relevance
/// gate that keeps model-judged automated/reply-less mail out of the review
/// queue (item 67), wired through the watcher pipeline on `AppState`.
@MainActor
final class AppStateReplyWorthinessGapsTests: XCTestCase {

    private func message(
        id: UInt32,
        uidValidity: UInt32? = nil,
        from: String = "alice@x.com",
        replyTo: String? = nil,
        messageID: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: uidValidity,
            from: MailAddress(name: "Alice", email: from),
            replyTo: replyTo.map { MailAddress(name: "Reply", email: $0) },
            subject: "Subject \(id)",
            date: "",
            messageID: messageID ?? "<\(id)@x.com>"
        )
    }

    private func baselineProcessed() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        return processed
    }

    private func makeAppState(
        fetch: Result<[MailMessage], MailError> = .success([]),
        header: Result<MailHeaderFields, MailError> = .success(MailHeaderFields()),
        body: Result<Data, MailError> = .success(Data("Please advise.".utf8)),
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: "On it.")),
        processed: ProcessedMessages? = nil
    ) -> (AppState, FakeAppMailProvider, AppStateMemoryPersistence) {
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
            processedMessages: processed ?? baselineProcessed()
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: fetch,
            bodyResult: body,
            headerResult: header
        )
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        return (appState, provider, persistence)
    }

    // MARK: - Both-address evaluation (item 66)

    func testNoReplyFromAddressIsSkippedDespiteRoutableReplyTo() async {
        // Evaluating BOTH addresses catches the known GitHub automated `From` /
        // `reply.github.com` routing pattern named in item 66.
        let (appState, provider, _) = makeAppState(
            fetch: .success([
                message(id: 1, from: "notifications@github.com", replyTo: "reply+abc@reply.github.com")
            ])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.noReplySender])
        // Caught on the sender-only pass, so no header fetch is spent.
        XCTAssertEqual(provider.headerFetchCallCount, 0)
    }

    func testRoutableReplyToPreventsGenericNotificationFromSkip() async {
        let (appState, provider, _) = makeAppState(
            fetch: .success([
                message(id: 1, from: "notifications@ats.example", replyTo: "recruiter@company.example")
            ])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertEqual(provider.headerFetchCallCount, 1)
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
    }

    func testPersonalFromAndReplyToStillDrafts() async {
        // A real person on both addresses is still worthy (no over-skip).
        let (appState, provider, _) = makeAppState(
            fetch: .success([
                message(id: 1, from: "alice@example.com", replyTo: "alice.work@example.com")
            ])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertEqual(provider.headerFetchCallCount, 1)
    }

    // MARK: - Transactional senders (item 66)

    func testTransactionalReceiptSenderIsSkippedAsAutomated() async {
        // Stripe/Anthropic receipt: `invoice+statements@` From, `support@`
        // Reply-To. Caught by the From's `invoice` base — and reported as an
        // automated notification, not a no-reply sender, since the Reply-To is
        // a staffed inbox.
        let (appState, provider, persistence) = makeAppState(
            fetch: .success([
                message(id: 1, from: "invoice+statements@stripe.com", replyTo: "support@stripe.com")
            ])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.automatedNotification])
        // Caught on the sender-only pass — no body/header cost spent.
        XCTAssertEqual(provider.bodyFetchCallCount, 0)
        XCTAssertEqual(provider.headerFetchCallCount, 0)
        // Sender-heuristic skips stay recoverable after log loss (not processed).
        XCTAssertFalse(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
    }

    func testHumanManagedTransactionalAliasStillDrafts() async {
        // The local part alone is not enough to skip. Human-managed aliases like
        // `invoice@accounting-firm.example` still pass through the watcher and get
        // drafted when headers do not corroborate automation.
        let (appState, provider, _) = makeAppState(
            fetch: .success([
                message(id: 1, from: "invoice@accounting-firm.example")
            ])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertEqual(provider.headerFetchCallCount, 1)
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
    }

    func testGenuineSupportSenderStillDrafts() async {
        // The bare `support@` that receipts point their Reply-To at must NOT be a
        // skip token on its own, or a real support back-and-forth would be lost.
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1, from: "support@vendor.com")])
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
    }

    // MARK: - LLM relevance gate (item 67)

    /// The model's own "automated / nothing to reply to" verdict: an explicit
    /// not-reply-worthy outcome, not an inferred empty missing-info list.
    private let automatedNeedsInfoResponse =
        "\(DraftGenerator.notReplyWorthySentinel) This is an automated receipt email and no reply is useful."

    /// A genuine item-13 "needs your input" verdict — a needs-info outcome whose
    /// `missing` list names specific things only the user can supply.
    private let genuineNeedsInfoResponse = """
    NEEDS_INFO: I can't confirm the meeting without the details only you have.
    - The meeting time you prefer
    - Which room to book
    """

    /// A genuine needs-info outcome whose actionable request lives in `summary`,
    /// with no optional bullet list.
    private let singleLineNeedsInfoResponse =
        "NEEDS_INFO: Need the invoice number."

    func testGenuineNeedsInfoWithMissingListStillEnqueuesAsFlaggedDraft() async {
        // Item 13 preserved: a needs-info draft with a populated `missing` list is
        // actionable, so it stays in the review queue as a flagged draft rather
        // than being routed to the skip log by the item 67 gate.
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1)]),
            completion: .success(LLMResponse(text: genuineNeedsInfoResponse))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertEqual(appState.pendingDrafts.first?.isFlagged, true)
        XCTAssertEqual(
            appState.pendingDrafts.first?.needsInfo?.missing,
            ["The meeting time you prefer", "Which room to book"]
        )
        XCTAssertTrue(appState.skippedMessages.isEmpty)
    }

    func testSingleLineNeedsInfoWithoutMissingListStillEnqueuesAsFlaggedDraft() async {
        // Regression for PR #56: optional bullet formatting is not the model-skip
        // signal. A one-line NEEDS_INFO response can be actionable via `summary`.
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1)]),
            completion: .success(LLMResponse(text: singleLineNeedsInfoResponse))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertEqual(appState.pendingDrafts.first?.isFlagged, true)
        XCTAssertEqual(appState.pendingDrafts.first?.needsInfo?.summary, "Need the invoice number.")
        XCTAssertEqual(appState.pendingDrafts.first?.needsInfo?.missing, [])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
    }

    func testExplicitModelNotReplyWorthyOutcomeRoutesToSkipNotQueue() async {
        let (appState, _, persistence) = makeAppState(
            fetch: .success([message(id: 1)]),
            completion: .success(LLMResponse(text: automatedNeedsInfoResponse))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.notReplyWorthyPerModel])
        // Keep model skips recoverable after app restart / skip-log loss: the
        // durable processed set must not permanently hide the "Draft anyway" path.
        XCTAssertFalse(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
    }

    func testModelSkippedMessageIsNotReevaluatedWhileSkipEntryExists() async {
        let (appState, provider, persistence) = makeAppState(
            fetch: .success([message(id: 1)]),
            completion: .success(LLMResponse(text: automatedNeedsInfoResponse))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()
        await appState.pollInboxOnce()

        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.notReplyWorthyPerModel])
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
        XCTAssertFalse(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
    }

    func testModelSkippedMessageCanReappearAfterSkipLogLoss() async {
        let (appState, provider, persistence) = makeAppState(
            fetch: .success([message(id: 1)]),
            completion: .success(LLMResponse(text: automatedNeedsInfoResponse))
        )
        appState.watchStatus = .watching
        await appState.pollInboxOnce()

        appState.clearSkippedMessages()
        await appState.pollInboxOnce()

        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.notReplyWorthyPerModel])
        XCTAssertEqual(provider.bodyFetchCallCount, 2)
        XCTAssertFalse(persistence.processedMessages.contains(message(id: 1), account: "me@gmail.com", mailbox: .inbox))
    }

    func testReadyModelOutcomeStillEnqueues() async {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1)]),
            completion: .success(LLMResponse(text: "Happy to help — sending it over."))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertEqual(appState.pendingDrafts.first?.isFlagged, false)
        XCTAssertTrue(appState.skippedMessages.isEmpty)
    }

    func testDraftAnywayReDraftsModelSkippedMessage() async throws {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1)]),
            completion: .success(LLMResponse(text: automatedNeedsInfoResponse))
        )
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        let entry = try XCTUnwrap(appState.skippedMessages.first)
        XCTAssertEqual(entry.reason, .notReplyWorthyPerModel)

        // "Draft anyway" bypasses the gate and enqueues the flagged draft for the
        // user to complete (item 13).
        let ok = await appState.forceDraftSkippedMessage(entry)

        XCTAssertTrue(ok)
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertEqual(appState.pendingDrafts.first?.isFlagged, true)
        XCTAssertEqual(
            appState.pendingDrafts.first?.notReplyWorthy?.summary,
            "This is an automated receipt email and no reply is useful."
        )
        XCTAssertTrue(appState.skippedMessages.isEmpty)
    }
}
