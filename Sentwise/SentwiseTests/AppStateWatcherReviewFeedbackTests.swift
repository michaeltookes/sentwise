import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateWatcherReviewFeedbackTests: XCTestCase {

    private func message(id: UInt32) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 10,
            from: MailAddress(name: "Alice", email: "alice@example.com"),
            subject: "Subject \(id)",
            date: "",
            messageID: "<\(id)@example.com>"
        )
    }

    private func processedBaseline() -> ProcessedMessages {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        processed.setBaselineUID(account: "me@gmail.com", mailbox: .inbox, uid: 1, uidValidity: 10)
        return processed
    }

    private func makeAppState(
        fetch: Result<[MailMessage], MailError>,
        completion: Result<LLMResponse, LLMError>,
        reachability: NetworkReachabilityMonitoring? = nil
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
            processedMessages: processedBaseline()
        )
        let provider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: fetch,
            bodyResult: .success(Data("Can you help?".utf8))
        )
        let llm = FakeLLMProvider(result: .success(()), completion: completion)
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: llm,
            reachability: reachability ?? FakeReachabilityMonitor()
        )
        appState.retryRunner = .immediate
        appState.inboxDrafting.autoDraftEnabled = true // item 108: exercise auto-generate pipeline
        return (appState, provider, persistence)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000)
            await Task.yield()
        }
    }

    func testDraftGenerationAuthFailurePausesWatchingAndRecordsAuthFailed() async {
        let (appState, _, persistence) = makeAppState(
            fetch: .success([message(id: 2)]),
            completion: .failure(.http(status: 401, message: "bad key"))
        )
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(appState.watchStatus, .paused)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertNotNil(appState.watchError)
        XCTAssertEqual(appState.activityEvents.map(\.kind), [.authFailed])
        XCTAssertEqual(persistence.loadActivityEvents().map(\.kind), [.authFailed])
    }

    func testWatcherPollWaitsForInitialReachabilityConfirmation() async {
        let reachability = FakeReachabilityMonitor(isOnline: true, hasCurrentPath: false)
        let (appState, provider, _) = makeAppState(
            fetch: .success([message(id: 2)]),
            completion: .success(LLMResponse(text: "On it.")),
            reachability: reachability
        )

        appState.startReachabilityMonitoring()
        appState.startWatching()
        await Task.yield()

        XCTAssertEqual(provider.fetchCallCount, 0)
        XCTAssertTrue(appState.pendingDrafts.isEmpty)

        reachability.setOnline(true)
        await waitUntil { appState.pendingDrafts.map(\.id) == [2] }
        appState.stopWatching()

        XCTAssertEqual(provider.fetchCallCount, 1)
    }

    func testWatcherRetryStopsWhenAccountChangesBeforeRetry() async {
        let provider = WatcherRetryBodyMailProvider(messages: [message(id: 2)])
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
            processedMessages: processedBaseline()
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(
                result: .success(()),
                completion: .success(LLMResponse(text: "On it."))
            )
        )
        appState.retryRunner = .immediate
        appState.inboxDrafting.autoDraftEnabled = true // item 108: exercise auto-generate pipeline
        provider.onFirstBodyFetch = {
            await MainActor.run {
                appState.mailEmail = "new@gmail.com"
                appState.mailAppPassword = "new-pw"
            }
        }
        appState.watchStatus = .watching

        await appState.pollInboxOnce()

        XCTAssertEqual(provider.bodyFetchEmails, ["me@gmail.com"])
        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertFalse(persistence.processedMessages.contains(
            message(id: 2),
            account: "me@gmail.com",
            mailbox: .inbox
        ))
        XCTAssertTrue(appState.watchError?.contains("email account changed") ?? false)
    }
}

final class WatcherRetryBodyMailProvider: MailProvider, @unchecked Sendable {
    private let messages: [MailMessage]
    private var bodyFetchCount = 0
    private(set) var bodyFetchEmails: [String] = []
    var onFirstBodyFetch: (() async -> Void)?

    init(messages: [MailMessage]) {
        self.messages = messages
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        messages
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        bodyFetchCount += 1
        bodyFetchEmails.append(credentials.email)
        if bodyFetchCount == 1 {
            await onFirstBodyFetch?()
            throw MailError.connectionFailed("temporary body fetch failure")
        }
        return Data("Can you help?".utf8)
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {}
}
