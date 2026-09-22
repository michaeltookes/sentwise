import SentwiseMail
import Foundation
import XCTest
@testable import Sentwise

@MainActor
final class StaleThreadRegenerationFallbackTests: XCTestCase {

    private func draft(id: UInt32 = 5, subject: String = "Lunch?") -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 1,
            sourceAccountEmail: "me@att.net",
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
        uidValidity: UInt32? = 1,
        inReplyTo: String? = nil,
        messageID: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: uidValidity,
            from: MailAddress(email: "alice@x.com"),
            subject: subject,
            date: "",
            inReplyTo: inReplyTo,
            messageID: messageID
        )
    }

    private func result(_ messages: [MailMessage]) -> MailSearchResult {
        MailSearchResult(messages: messages, totalMatches: messages.count, offset: 0, hasMore: false)
    }

    private func hasHeader(_ criteria: MailSearchCriteria, field: String, value: String) -> Bool {
        criteria.headers.contains(MailHeaderSearch(field: field, value: value))
    }

    private func makeAppState(provider: MailProvider, llmText: String) -> AppState {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@att.net",
            mailHost: "imap.mail.att.net",
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

    func testRegeneratePendingDraftFallsBackToArchiveWhenProviderHasNoAllMail() async {
        let staleDraft = draft()
        let movedSource = message(id: 50, subject: "Lunch?", uidValidity: 99, messageID: "<orig@x.com>")
        let newerReply = message(
            id: 55,
            subject: "Updated plan",
            uidValidity: 99,
            inReplyTo: "<orig@x.com>",
            messageID: "<new@x.com>"
        )
        let provider = SearchStubMailProvider()
        provider.searchHandler = { [weak self] mailbox, criteria, _, _ in
            guard let self else { return nil }
            if mailbox == .inbox && criteria.subject == "lunch?" { return .empty(offset: 0) }
            if mailbox == .named("INBOX") { return .empty(offset: 0) }
            if mailbox == .named("Archive") && self.hasHeader(criteria, field: "Message-ID", value: "orig@x.com") {
                return self.result([movedSource])
            }
            if mailbox == .named("Archive") && self.hasHeader(criteria, field: "In-Reply-To", value: "orig@x.com") {
                return self.result([newerReply])
            }
            return .empty(offset: 0)
        }
        let appState = makeAppState(provider: provider, llmText: "Regenerated archive reply.")
        appState.pendingDrafts = [staleDraft]

        await appState.regeneratePendingDraft(staleDraft)

        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(appState.pendingDrafts.first?.id, 55)
        XCTAssertEqual(appState.pendingDrafts.first?.sourceMailbox, "Archive")
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Regenerated archive reply.")
        XCTAssertEqual(provider.lastBodyUID, 55)
        XCTAssertEqual(provider.lastBodyMailbox, .named("Archive"))
        XCTAssertTrue(provider.searchRequests.contains {
            $0.mailbox == .named("Archive") && hasHeader($0.criteria, field: "Message-ID", value: "orig@x.com")
        })
    }

    func testDraftAwaitingRequestFallsBackToArchiveWhenOriginalMailboxMoved() async {
        var awaitingDraft = draft()
        awaitingDraft.body = ""
        awaitingDraft.awaitingRequest = DraftAwaitingRequest()
        let movedSource = message(id: 50, subject: "Lunch?", uidValidity: 99, messageID: "<orig@x.com>")
        let newerReply = message(
            id: 55,
            subject: "Updated plan",
            uidValidity: 99,
            inReplyTo: "<orig@x.com>",
            messageID: "<new@x.com>"
        )
        let provider = SearchStubMailProvider()
        provider.searchHandler = { [weak self] mailbox, criteria, _, _ in
            guard let self else { return nil }
            if mailbox == .inbox && criteria.subject == "lunch?" { return .empty(offset: 0) }
            if mailbox == .named("INBOX") { return .empty(offset: 0) }
            if mailbox == .named("Archive") && self.hasHeader(criteria, field: "Message-ID", value: "orig@x.com") {
                return self.result([movedSource])
            }
            if mailbox == .named("Archive") && self.hasHeader(criteria, field: "In-Reply-To", value: "orig@x.com") {
                return self.result([newerReply])
            }
            return .empty(offset: 0)
        }
        let appState = makeAppState(provider: provider, llmText: "Generated archive click reply.")
        appState.pendingDrafts = [awaitingDraft]

        await appState.draftAwaitingRequest(awaitingDraft)

        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertEqual(appState.pendingDrafts.first?.id, 55)
        XCTAssertEqual(appState.pendingDrafts.first?.sourceMailbox, "Archive")
        XCTAssertEqual(appState.pendingDrafts.first?.body, "Generated archive click reply.")
        XCTAssertFalse(appState.pendingDrafts.first?.isAwaitingDraftRequest ?? true)
        XCTAssertEqual(provider.lastBodyUID, 55)
        XCTAssertEqual(provider.lastBodyMailbox, .named("Archive"))
    }
}
