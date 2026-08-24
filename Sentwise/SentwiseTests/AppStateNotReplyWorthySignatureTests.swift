import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateNotReplyWorthySignatureTests: XCTestCase {

    func testEditedNotReplyWorthyOverrideAppliesCustomSignature() async {
        let draft = pendingDraft(
            body: "",
            notReplyWorthy: DraftNotReplyWorthy(summary: "This receipt does not need a reply.")
        )
        let (appState, provider) = makeAppState(sendBehavior: .autoSend, seed: [draft])
        appState.signaturePolicy = .custom
        appState.signatureText = "Best,\nMe"

        await appState.approvePendingDraft(draft, withEditedBody: "Thanks for the receipt.")

        XCTAssertEqual(decodedBody(from: provider.sentRFC822), "Thanks for the receipt.\n\nBest,\nMe")
        XCTAssertNil(appState.approvalError)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
    }

    private func pendingDraft(
        id: UInt32 = 1,
        body: String,
        notReplyWorthy: DraftNotReplyWorthy
    ) -> Draft {
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
            body: body,
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            notReplyWorthy: notReplyWorthy
        )
    }

    private func makeAppState(
        sendBehavior: SendBehavior,
        seed drafts: [Draft]
    ) -> (AppState, FakeAppMailProvider) {
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
            sendBehavior: sendBehavior.rawValue,
            sendDelaySeconds: 0
        ), pendingDrafts: drafts)
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        return (appState, provider)
    }

    private func decodedBody(from rfc822: Data?) -> String {
        guard let rfc822, let text = String(data: rfc822, encoding: .utf8),
              let separator = text.range(of: "\r\n\r\n") else {
            return ""
        }
        let encoded = text[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8) else {
            return ""
        }
        return decoded
    }
}
