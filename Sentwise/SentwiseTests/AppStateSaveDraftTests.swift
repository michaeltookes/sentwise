import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateSaveDraftTests: XCTestCase {

    private func draft() -> Draft {
        Draft(
            id: 5,
            sourceUIDValidity: 1,
            sourceAccountEmail: "me@gmail.com",
            sourceSubject: "Lunch?",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<orig@example.com>",
            replySubject: "Re: Lunch?",
            body: "Sounds good!",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeAppState(
        appendResult: Result<Void, MailError> = .success(())
    ) -> (AppState, FakeAppMailProvider) {
        let secrets = InMemorySecretStore(seed: [.llmAPIKey(provider: "anthropic"): "sk-live"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let provider = FakeAppMailProvider(result: .success(()), appendResult: appendResult)
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        appState.mailAppPassword = "app-pw"
        appState.generatedDraft = draft()
        return (appState, provider)
    }

    func testSaveDraftAppendsToDraftsWithDraftFlag() async {
        let (appState, provider) = makeAppState()

        await appState.saveGeneratedDraftToDrafts()

        XCTAssertEqual(provider.appendedMailbox, .drafts)
        XCTAssertEqual(provider.appendedFlags, [.draft])
        XCTAssertNotNil(appState.draftSavedMessage)
        XCTAssertNil(appState.draftError)
        XCTAssertFalse(appState.isSavingDraft)
        XCTAssertNil(appState.generatedDraft)

        let rfc822 = String(data: provider.appendedRFC822 ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(rfc822.contains("To: alice@example.com"))
        XCTAssertTrue(rfc822.contains("Subject: Re: Lunch?"))
        XCTAssertTrue(rfc822.contains("In-Reply-To: <orig@example.com>"))
        XCTAssertTrue(rfc822.contains("From: me@gmail.com"))
    }

    func testSaveDraftSurfacesError() async {
        let (appState, _) = makeAppState(appendResult: .failure(.commandFailed("APPEND failed")))

        await appState.saveGeneratedDraftToDrafts()

        XCTAssertNil(appState.draftSavedMessage)
        XCTAssertNotNil(appState.draftError)
        XCTAssertFalse(appState.isSavingDraft)
    }

    func testSaveDraftWithoutGeneratedDraftIsNoOp() async {
        let (appState, provider) = makeAppState()
        appState.generatedDraft = nil

        await appState.saveGeneratedDraftToDrafts()

        XCTAssertNil(provider.appendedRFC822)
        XCTAssertNil(appState.draftSavedMessage)
    }

    func testOutgoingMessageBuiltFromDraft() {
        let message = AppState.outgoingMessage(
            for: draft(),
            from: "me@gmail.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            messageID: "<new@gmail.com>"
        )
        XCTAssertEqual(message.to, ["alice@example.com"])
        XCTAssertEqual(message.subject, "Re: Lunch?")
        XCTAssertEqual(message.inReplyTo, "<orig@example.com>")
        XCTAssertEqual(message.references, ["<orig@example.com>"])
    }

    func testOutgoingMessagePrefersReplyToAddress() {
        var draft = draft()
        draft.sourceReplyTo = MailAddress(name: "Team Inbox", email: "team@example.com")

        let message = AppState.outgoingMessage(
            for: draft,
            from: "me@gmail.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            messageID: "<new@gmail.com>"
        )

        XCTAssertEqual(message.to, ["team@example.com"])
    }

    func testGeneratedMessageIDUsesSenderDomain() {
        let id = AppState.generateMessageID(forEmail: "me@gmail.com")
        XCTAssertTrue(id.hasSuffix("@gmail.com>"))
        XCTAssertTrue(id.hasPrefix("<"))
    }
}
