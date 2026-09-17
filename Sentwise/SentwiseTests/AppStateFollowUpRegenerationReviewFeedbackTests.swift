import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateFollowUpRegenFeedbackTests: XCTestCase {

    func testRegenerateAuthoredFollowUpUsesSourceAccountCredentials() async {
        let backgroundEmail = "side@work.com"
        let draft = Draft(
            id: 42,
            sourceUIDValidity: nil,
            sourceAccountEmail: backgroundEmail,
            sourceMailHost: "imap.work.com",
            sourceMailPort: 993,
            sourceSubject: "Follow-up: Sync",
            sourceFrom: MailAddress(email: "dana@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: nil,
            incomingBody: "Marcus: send the deck Friday.",
            replySubject: "Follow-up: Sync",
            body: "Old follow-up.",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            authoredRecipients: [MailAddress(email: "dana@example.com")],
            followUpContext: .summary("Marcus will send the deck Friday.", hasSpeakerLabels: false)
        )
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ), pendingDrafts: [draft])
        let app = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(seed: [
                .mailAppPassword: "app-pw",
                .llmAPIKey(provider: "anthropic"): "sk-live"
            ]),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(
                result: .success(()),
                completion: .success(LLMResponse(text: "Regenerated follow-up."))
            )
        )
        app.pendingDrafts = [draft]
        app.pendingDraftCount = 1
        app.backgroundConnectedAccounts = [
            ConnectedMailAccount(
                email: backgroundEmail,
                host: "imap.work.com",
                port: 993,
                appPassword: "side-pw"
            )
        ]

        await app.regeneratePendingDraft(draft)

        XCTAssertNil(app.approvalError)
        XCTAssertEqual(app.pendingDrafts.first?.sourceAccountEmail, backgroundEmail)
        XCTAssertEqual(app.pendingDrafts.first?.body, "Regenerated follow-up.")
    }
}
