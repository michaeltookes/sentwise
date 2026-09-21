import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateWatcherFetchExpansionTests: XCTestCase {

    func testPollFetchesPastRecentWindowUntilBaselineStartWhenUIDValidityChanges() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var processed = baselineWithStartProcessed(start)
        processed.setBaselineUID(account: "me@gmail.com", mailbox: .inbox, uid: 100, uidValidity: 1)
        for id in 121...130 {
            processed.insert(
                message(
                    id: UInt32(id),
                    uidValidity: 2,
                    date: "Tue, 14 Nov 2023 22:13:21 +0000"
                ),
                account: "me@gmail.com",
                mailbox: .inbox
            )
        }

        let provider = PrefixMailProvider(messages: postStartMessages() + historicalMessages())
        let appState = makeAppState(provider: provider, processed: processed)
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(provider.fetchLimits, [20, 40])
        XCTAssertEqual(appState.pendingDrafts.map(\.id), Array(UInt32(101)...UInt32(120)))
        XCTAssertEqual(provider.bodyFetchCallCount, 20)
    }

    private func makeAppState(provider: PrefixMailProvider, processed: ProcessedMessages) -> AppState {
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
            processedMessages: processed
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()), completion: .success(LLMResponse(text: "On it.")))
        )
        appState.inboxDrafting.autoDraftEnabled = true // item 108: exercise auto-generate pipeline
        return appState
    }

    private func baselineWithStartProcessed(_ date: Date) -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        processed.setBaselineStart(account: "me@gmail.com", mailbox: .inbox, date: date)
        return processed
    }

    private func postStartMessages() -> [MailMessage] {
        (101...130).reversed().map {
            message(
                id: UInt32($0),
                uidValidity: 2,
                messageID: "<\($0)@x.com>",
                date: "Tue, 14 Nov 2023 22:13:21 +0000"
            )
        }
    }

    private func historicalMessages() -> [MailMessage] {
        (91...100).reversed().map {
            message(
                id: UInt32($0),
                uidValidity: 2,
                messageID: "<\($0)@x.com>",
                date: "Tue, 14 Nov 2023 22:13:19 +0000"
            )
        }
    }

    private func message(
        id: UInt32,
        uidValidity: UInt32?,
        messageID: String? = nil,
        date: String
    ) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: uidValidity,
            from: MailAddress(name: "Alice", email: "alice@x.com"),
            subject: "Subject \(id)",
            date: date,
            messageID: messageID
        )
    }
}
