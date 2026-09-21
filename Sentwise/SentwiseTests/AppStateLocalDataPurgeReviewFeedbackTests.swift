import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class LocalDataPurgeFeedbackTests: XCTestCase {

    private func message(id: UInt32) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 7,
            from: MailAddress(name: "Sender", email: "sender\(id)@example.com"),
            subject: "Subject \(id)",
            date: "",
            messageID: "<\(id)@example.com>"
        )
    }

    private func skipped(_ id: UInt32, account: String, reason: ReplyWorthinessReason) -> SkippedMessage {
        SkippedMessage(message: message(id: id), mailbox: .inbox, account: account, reason: reason)
    }

    func testScopedPurgeRebuildsSkippedLookupMapsFromAllRetainedAccounts() throws {
        let focused = "me@gmail.com"
        let purged = "old@work.com"
        let retainedBackground = "side@work.com"
        let focusedSkip = skipped(1, account: focused, reason: .noReplySender)
        let purgedSkip = skipped(2, account: purged, reason: .notReplyWorthyPerModel)
        let retainedSkip = skipped(3, account: retainedBackground, reason: .senderBlocklisted)
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: focused,
                savedAccounts: [
                    SavedMailAccount(email: focused, host: "imap.gmail.com", port: 993),
                    SavedMailAccount(email: purged, host: "imap.work.com", port: 993),
                    SavedMailAccount(email: retainedBackground, host: "imap.work.com", port: 993)
                ]
            ),
            skippedMessages: [focusedSkip, purgedSkip, retainedSkip]
        )
        let app = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(seed: [.mailAppPassword(email: focused): "app-pw"]),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )

        try app.purgeLocalMailArtifacts(for: purged, includeUnscopedArtifacts: false)

        XCTAssertEqual(app.skippedMessages.map(\.account), [focused])
        XCTAssertEqual(app.skippedMessageIDs, Set([focusedSkip.id, retainedSkip.id]))
        XCTAssertEqual(app.skippedMessageReasonsByID[retainedSkip.id], .senderBlocklisted)
        XCTAssertNil(app.skippedMessageReasonsByID[purgedSkip.id])
    }

    func testEraseAllClearsInboxDraftingPolicyAndAutoDraftBudgetStore() async {
        let budgetStore = InMemoryAutoDraftBudgetStore()
        budgetStore.save(AutoDraftBudgetState(
            accountKey: "acct-test",
            windowResetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            used: 3,
            capAlertFired: true
        ))
        let app = AppState(
            persistence: AppStateMemoryPersistence(settings: .default),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        app.inboxDrafting = InboxDraftingSettings(
            autoDraftEnabled: true,
            autoDraftSenders: [SenderRule(normalized: "client.com")],
            monthlyAutoDraftBudget: 7
        )
        app.autoDraftBudgetStore = budgetStore

        let result = await app.eraseAllLocalData()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(app.inboxDrafting, InboxDraftingSettings())
        XCTAssertNil(budgetStore.loadState(for: "acct-test"))
    }
}
