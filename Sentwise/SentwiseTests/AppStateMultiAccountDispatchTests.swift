import SentwiseMail
import XCTest
@testable import Sentwise

/// Per-source-account dispatch (item 99): a reply is sent/saved from the mailbox
/// the original message arrived in, even when a different account is focused —
/// and a draft whose source account is not connected is blocked.
@MainActor
final class AppStateMultiAccountDispatchTests: XCTestCase {

    private let focused = "me@gmail.com"
    private let background = "side@work.com"

    private func draft(id: UInt32 = 1, sourceAccountEmail: String?, mailbox: String = "INBOX") -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: sourceAccountEmail,
            sourceMailbox: mailbox,
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

    private func makeAppState(
        seed: [Draft]
    ) -> (AppState, FakeAppMailProvider, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: focused): "gmail-pw",
            .mailAppPassword(email: background): "side-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let store = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: focused,
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6"
            ),
            pendingDrafts: seed
        )
        let provider = FakeAppMailProvider(result: .success(()))
        let app = AppState(
            persistence: store,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        app.mailAppPassword = "gmail-pw"
        app.backgroundConnectedAccounts = [
            ConnectedMailAccount(email: background, host: "imap.work.com", port: 993, appPassword: "side-pw")
        ]
        return (app, provider, store)
    }

    func testBackgroundAccountDraftDispatchesFromThatAccount() async {
        let backgroundDraft = draft(sourceAccountEmail: background)
        let (app, provider, _) = makeAppState(seed: [backgroundDraft])
        app.sendBehavior = .autoSend
        app.sendDelaySeconds = 0

        await app.approveDraft(backgroundDraft)

        // The reply went out over the background account's SMTP identity, not the
        // focused account's.
        XCTAssertEqual(provider.sentEnvelope?.sender, background)
        XCTAssertNil(app.approvalError)
        XCTAssertTrue(app.pendingDrafts.isEmpty)
    }

    func testFocusedAccountDraftStillDispatchesFromFocusedAccount() async {
        let focusedDraft = draft(sourceAccountEmail: focused)
        let (app, provider, _) = makeAppState(seed: [focusedDraft])
        app.sendBehavior = .autoSend
        app.sendDelaySeconds = 0

        await app.approveDraft(focusedDraft)

        XCTAssertEqual(provider.sentEnvelope?.sender, focused)
        XCTAssertNil(app.approvalError)
    }

    func testDraftFromUnconnectedAccountIsBlocked() async {
        let strayDraft = draft(sourceAccountEmail: "stranger@nowhere.com")
        let (app, provider, _) = makeAppState(seed: [strayDraft])
        app.sendBehavior = .autoSend
        app.sendDelaySeconds = 0

        await app.approveDraft(strayDraft)

        XCTAssertNil(provider.sentRFC822)
        XCTAssertEqual(app.approvalError, "This draft was generated for a different email account.")
        XCTAssertEqual(app.pendingDrafts.map(\.identity), [strayDraft.identity])
    }
}
