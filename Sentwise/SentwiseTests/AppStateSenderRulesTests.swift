import SentwiseMail
import XCTest
@testable import Sentwise

/// Tests the sender allow/blocklist wired into the watcher pipeline (item 18):
/// blocklisted senders are skipped with a visible reason, allowlisted senders are
/// force-drafted past the reply-worthiness heuristics, edits take effect on the
/// next poll, and the two lists stay mutually exclusive at a given pattern.
@MainActor
final class AppStateSenderRulesTests: XCTestCase {

    private func message(id: UInt32, from: String = "alice@x.com") -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: nil,
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

    private func makeAppState(
        fetch: Result<[MailMessage], MailError> = .success([]),
        header: Result<MailHeaderFields, MailError> = .success(MailHeaderFields()),
        completion: Result<LLMResponse, LLMError> = .success(LLMResponse(text: "On it."))
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
            processedMessages: baselineProcessed()
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: fetch,
            bodyResult: .success(Data("Please advise.".utf8)),
            headerResult: header
        )
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        return (appState, provider, persistence)
    }

    // MARK: - Blocklist

    func testBlocklistedDomainIsSkippedWithReason() async {
        let (appState, provider, persistence) = makeAppState(
            fetch: .success([message(id: 1, from: "friend@spam.net")])
        )
        appState.senderBlocklist = [SenderRule(normalized: "spam.net")]
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.senderBlocklisted])
        // Blocked before any costly fetch, and not durably processed so a mistaken
        // block can be recovered after the log is cleared.
        XCTAssertEqual(provider.headerFetchCallCount, 0)
        XCTAssertEqual(provider.bodyFetchCallCount, 0)
        XCTAssertFalse(
            persistence.processedMessages.contains(message(id: 1, from: "friend@spam.net"),
                                                   account: "me@gmail.com", mailbox: .inbox)
        )
    }

    func testBlocklistedAddressIsSkipped() async {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1, from: "nuisance@x.com")])
        )
        appState.senderBlocklist = [SenderRule(normalized: "nuisance@x.com")]
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.senderBlocklisted])
    }

    func testExistingBlocklistSkipDoesNotRefreshActivityEveryPoll() async throws {
        let blocked = message(id: 1, from: "friend@spam.net")
        let (appState, _, persistence) = makeAppState(fetch: .success([blocked]))
        appState.senderBlocklist = [SenderRule(normalized: "spam.net")]
        appState.watchStatus = .watching

        await appState.pollInboxOnce()
        let originalEvent = try XCTUnwrap(appState.activityEvents.first)
        XCTAssertEqual(originalEvent.skipReason, .senderBlocklisted)
        XCTAssertEqual(persistence.activityEventSaveCount, 1)

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.senderBlocklisted])
        XCTAssertEqual(persistence.activityEventSaveCount, 1)
        XCTAssertEqual(appState.activityEvents.first?.id, originalEvent.id)
        XCTAssertEqual(appState.activityEvents.first?.timestamp, originalEvent.timestamp)
    }

    // MARK: - Allowlist

    func testAllowlistForceDraftsPastWorthinessHeuristics() async {
        // A no-reply sender would normally be skipped by item 17, but an explicit
        // allowlist entry forces the draft and bypasses the header-fetch entirely.
        let (appState, provider, _) = makeAppState(
            fetch: .success([message(id: 1, from: "no-reply@x.com")])
        )
        appState.senderAllowlist = [SenderRule(normalized: "no-reply@x.com")]
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertEqual(provider.headerFetchCallCount, 0)
    }

    func testAllowlistForceDraftsPastBulkHeaders() async {
        // Bulk/list headers would skip this, but the allowlisted domain wins.
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1, from: "news@x.com")]),
            header: .success(MailHeaderFields(listUnsubscribe: "<mailto:unsub@x.com>"))
        )
        appState.senderAllowlist = [SenderRule(normalized: "x.com")]
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
    }

    func testAllowlistForceDraftsPastModelNotReplyWorthyGate() async {
        let skippedByModel = "\(DraftGenerator.notReplyWorthySentinel) This looks automated."
        let allowlisted = message(id: 1, from: "vip@x.com")
        let (appState, _, persistence) = makeAppState(
            fetch: .success([allowlisted]),
            completion: .success(LLMResponse(text: skippedByModel))
        )
        appState.senderAllowlist = [SenderRule(normalized: "vip@x.com")]
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertEqual(appState.pendingDrafts.first?.notReplyWorthy?.summary, "This looks automated.")
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertTrue(persistence.processedMessages.contains(allowlisted, account: "me@gmail.com", mailbox: .inbox))
    }

    // MARK: - Precedence

    func testAddressAllowBeatsDomainBlockInPipeline() async {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1, from: "vip@x.com")])
        )
        appState.senderBlocklist = [SenderRule(normalized: "x.com")]
        appState.senderAllowlist = [SenderRule(normalized: "vip@x.com")]
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
    }

    // MARK: - Runtime edits take effect on the next poll

    func testRuleAddedAtRuntimeTakesEffectOnNextPoll() async {
        let (appState, _, _) = makeAppState(
            fetch: .success([message(id: 1, from: "friend@block-me.com")])
        )
        appState.watchStatus = .watching

        // No rule yet → the message would be drafted; add a block rule, then poll.
        XCTAssertTrue(appState.addBlockedSender("block-me.com"))
        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.senderBlocklisted])
    }

    func testAllowlistReconsidersAlreadySkippedMessageOnNextPoll() async {
        let skipped = message(id: 1, from: "no-reply@x.com")
        let (appState, _, persistence) = makeAppState(fetch: .success([skipped]))
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.noReplySender])

        XCTAssertTrue(appState.addAllowedSender("no-reply@x.com"))
        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertFalse(appState.hasSkippedMessage(skipped, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertTrue(persistence.processedMessages.contains(skipped, account: "me@gmail.com", mailbox: .inbox))
    }

    func testAllowlistDoesNotDraftWhenSkipRemovalFails() async {
        let skipped = message(id: 1, from: "no-reply@x.com")
        let (appState, provider, persistence) = makeAppState(fetch: .success([skipped]))
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.noReplySender])
        XCTAssertEqual(provider.bodyFetchCallCount, 0)

        XCTAssertTrue(appState.addAllowedSender("no-reply@x.com"))
        persistence.skippedMessageSaveError = AppStatePersistenceError.writeDenied
        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.message.id), [1])
        XCTAssertEqual(persistence.skippedMessages.map(\.message.id), [1])
        XCTAssertTrue(appState.hasSkippedMessage(skipped, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertFalse(persistence.processedMessages.contains(skipped, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(provider.bodyFetchCallCount, 0)

        persistence.skippedMessageSaveError = nil
        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertFalse(appState.hasSkippedMessage(skipped, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertTrue(persistence.processedMessages.contains(skipped, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
    }

    func testRemovingBlockRuleReconsidersSkippedMessageOnNextPoll() async {
        let blocked = message(id: 1, from: "friend@spam.net")
        let (appState, _, persistence) = makeAppState(fetch: .success([blocked]))
        appState.senderBlocklist = [SenderRule(normalized: "spam.net")]
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.senderBlocklisted])

        appState.removeBlockedSenders([SenderRule(normalized: "spam.net")])
        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertFalse(appState.hasSkippedMessage(blocked, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertTrue(persistence.processedMessages.contains(blocked, account: "me@gmail.com", mailbox: .inbox))
    }

    func testRemovingBlockRuleDoesNotDraftWhenSkipRemovalFails() async {
        let blocked = message(id: 1, from: "friend@spam.net")
        let (appState, provider, persistence) = makeAppState(fetch: .success([blocked]))
        appState.senderBlocklist = [SenderRule(normalized: "spam.net")]
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        XCTAssertEqual(appState.skippedMessages.map(\.reason), [.senderBlocklisted])
        XCTAssertEqual(provider.bodyFetchCallCount, 0)

        appState.removeBlockedSenders([SenderRule(normalized: "spam.net")])
        persistence.skippedMessageSaveError = AppStatePersistenceError.writeDenied
        await appState.pollInboxOnce()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.map(\.message.id), [1])
        XCTAssertEqual(persistence.skippedMessages.map(\.message.id), [1])
        XCTAssertTrue(appState.hasSkippedMessage(blocked, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertFalse(persistence.processedMessages.contains(blocked, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(provider.bodyFetchCallCount, 0)

        persistence.skippedMessageSaveError = nil
        await appState.pollInboxOnce()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertFalse(appState.hasSkippedMessage(blocked, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertTrue(persistence.processedMessages.contains(blocked, account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(provider.bodyFetchCallCount, 1)
    }

    // MARK: - Mutations

    func testAddingToOneListRemovesIdenticalPatternFromTheOther() {
        let (appState, _, _) = makeAppState()

        XCTAssertTrue(appState.addAllowedSender("alice@x.com"))
        XCTAssertEqual(appState.senderAllowlist.map(\.pattern), ["alice@x.com"])

        XCTAssertTrue(appState.addBlockedSender("Alice@X.com"))
        XCTAssertTrue(appState.senderAllowlist.isEmpty)
        XCTAssertEqual(appState.senderBlocklist.map(\.pattern), ["alice@x.com"])
    }

    func testAddRejectsInvalidInput() {
        let (appState, _, _) = makeAppState()

        XCTAssertFalse(appState.addAllowedSender("   "))
        XCTAssertFalse(appState.addBlockedSender("foo@"))
        XCTAssertTrue(appState.senderAllowlist.isEmpty)
        XCTAssertTrue(appState.senderBlocklist.isEmpty)
    }

    func testRemoveSenderRule() {
        let (appState, _, _) = makeAppState()
        XCTAssertTrue(appState.addBlockedSender("spam.net"))
        XCTAssertTrue(appState.addBlockedSender("evil.org"))

        appState.removeBlockedSenders([SenderRule(normalized: "spam.net")])

        XCTAssertEqual(appState.senderBlocklist.map(\.pattern), ["evil.org"])
    }

    func testRulesAreIncludedInBuiltSettings() {
        let (appState, _, _) = makeAppState()
        XCTAssertTrue(appState.addAllowedSender("vip@x.com"))
        XCTAssertTrue(appState.addBlockedSender("spam.net"))

        let settings = appState.buildSettings()

        XCTAssertEqual(settings.senderAllowlist.map(\.pattern), ["vip@x.com"])
        XCTAssertEqual(settings.senderBlocklist.map(\.pattern), ["spam.net"])
    }
}
