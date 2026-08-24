import SentwiseMail
import XCTest
@testable import Sentwise

/// Verifies the data the redesigned Review Drafts window's two tabs render
/// (item 69): the Drafts tab is driven by `pendingDrafts` and the Skipped tab by
/// `skippedMessages`, the two are disjoint, and the Skipped tab's actions
/// ("Draft anyway" / dismiss / clear) still operate on the skip log alone.
@MainActor
final class AppStateReviewTabsTests: XCTestCase {

    private func message(id: UInt32, from: String) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 7,
            from: MailAddress(name: nil, email: from),
            subject: "Subject \(id)",
            date: "",
            messageID: "<\(id)@x.com>"
        )
    }

    private func pendingDraft(id: UInt32) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: "INBOX",
            sourceSubject: "Lunch?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            incomingBody: "Are you free Thursday?",
            replySubject: "Re: Lunch?",
            body: "Thursday works!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func baselineProcessed() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        return processed
    }

    /// Builds an AppState seeded with `drafts` as pending and a mail provider that
    /// returns a no-reply message (auto-flagged as list mail) so a poll records
    /// exactly one skip.
    private func makeAppState(seed drafts: [Draft]) -> AppState {
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
            pendingDrafts: drafts
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: .success([message(id: 900, from: "no-reply@x.com")]),
            bodyResult: .success(Data("Automated notice.".utf8)),
            headerResult: .success(MailHeaderFields(listUnsubscribe: "<mailto:unsub@x.com>"))
        )
        let llm = FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "On it.")))
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: provider, llm: llm)
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return appState
    }

    func testDraftsAndSkippedTabsAreDisjoint() async throws {
        let appState = makeAppState(seed: [pendingDraft(id: 1)])
        appState.watchStatus = .watching
        await appState.pollInboxOnce()

        // Drafts tab shows only the pending draft.
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        // Skipped tab shows only the skipped message.
        let skipped = try XCTUnwrap(appState.skippedMessages.first)
        XCTAssertEqual(appState.skippedMessages.count, 1)
        XCTAssertEqual(skipped.message.id, 900)

        // The two surfaces never share an entry.
        let pendingIDs = Set(appState.pendingDrafts.map(\.id))
        let skippedIDs = Set(appState.skippedMessages.map(\.message.id))
        XCTAssertTrue(pendingIDs.isDisjoint(with: skippedIDs))
    }

    func testDismissSkippedLeavesDraftsTabUntouched() async throws {
        let appState = makeAppState(seed: [pendingDraft(id: 1)])
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        let entry = try XCTUnwrap(appState.skippedMessages.first)

        appState.dismissSkippedMessage(entry)

        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1], "dismissing a skip must not touch the drafts tab")
    }

    func testClearSkippedLeavesDraftsTabUntouched() async throws {
        let appState = makeAppState(seed: [pendingDraft(id: 1)])
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        XCTAssertFalse(appState.skippedMessages.isEmpty)

        appState.dismissAllSkippedMessages()

        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
    }

    func testDraftAnywayMovesSkippedIntoDraftsTab() async throws {
        let appState = makeAppState(seed: [])
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        let entry = try XCTUnwrap(appState.skippedMessages.first)

        await appState.forceDraftSkippedMessage(entry)

        // The overridden message left the Skipped tab and became a reviewable draft.
        XCTAssertFalse(appState.skippedMessages.contains { $0.id == entry.id })
        XCTAssertTrue(appState.pendingDrafts.contains { $0.id == entry.message.id })
    }

    func testSuccessfulDraftAnywaySwitchesReviewSelectionToDrafts() async throws {
        let appState = makeAppState(seed: [])
        let selection = ReviewWindowSelection(selectedTab: .skipped)
        appState.watchStatus = .watching
        await appState.pollInboxOnce()
        let entry = try XCTUnwrap(appState.skippedMessages.first)

        let didCreateDraft = await appState.forceDraftSkippedMessage(entry)
        selection.selectDraftsAfterSuccessfulOverride(didCreateDraft)

        XCTAssertEqual(selection.selectedTab, .drafts)
    }

    func testFailedDraftAnywayLeavesReviewSelectionOnSkipped() {
        let selection = ReviewWindowSelection(selectedTab: .skipped)

        selection.selectDraftsAfterSuccessfulOverride(false)

        XCTAssertEqual(selection.selectedTab, .skipped)
    }
}
