import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateDispatchLifecycleTests: XCTestCase {

    private func pendingDraft(id: UInt32 = 1) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: "me@gmail.com",
            sourceMailbox: Mailbox.inbox.imapName,
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

    private func connectedSettings() -> Settings {
        Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6",
            sendBehavior: SendBehavior.autoSend.rawValue,
            sendDelaySeconds: 0
        )
    }

    private func makeTransitionAppState(
        persistence: AppStateMemoryPersistence,
        secrets: SecretStore,
        online: Bool = false
    ) -> AppState {
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: ResilienceMailProvider(sendResults: [.success(())]),
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier(),
            reachability: FakeReachabilityMonitor(isOnline: online)
        )
        appState.retryRunner = .immediate
        return appState
    }

    private func makeAppState(
        online: Bool = true,
        sendResults: [Result<Void, MailError>] = [.success(())],
        seed drafts: [Draft] = []
    ) -> (AppState, ResilienceMailProvider, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(
            settings: connectedSettings(),
            pendingDrafts: drafts
        )
        let provider = ResilienceMailProvider(sendResults: sendResults)
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            notifier: FakeDraftNotifier(),
            reachability: FakeReachabilityMonitor(isOnline: online)
        )
        appState.pendingDrafts = drafts
        appState.pendingDraftCount = drafts.count
        appState.retryRunner = .immediate
        return (appState, provider, persistence)
    }

    func testSendRetryStopsWhenActiveAccountChangesDuringBackoff() async {
        let draft = pendingDraft()
        let (appState, provider, _) = makeAppState(
            sendResults: [.failure(.connectionFailed("offline"))],
            seed: [draft]
        )
        appState.retryRunner = RetryRunner(
            sleep: { _ in
                await MainActor.run {
                    appState.mailEmail = "other@gmail.com"
                    appState.mailAppPassword = "other-pw"
                }
            },
            randomUnitInterval: { 0.5 }
        )

        await appState.approveDraft(draft)

        XCTAssertEqual(provider.sendCallCount, 1)
        XCTAssertEqual(appState.pendingDrafts.map(\.identity), [draft.identity])
        XCTAssertTrue(appState.approvalError?.contains("email account changed") ?? false)
    }

    func testAccountSwitchPreservesQueuedIntentForRetainedAccount() async {
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        var queuedDraft = pendingDraft()
        queuedDraft.offlineQueuedDispatch = intent
        let (appState, _, persistence) = makeAppState(online: false, seed: [queuedDraft])
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        await appState.testConnection(with: MailAccountCredentials(
            email: "other@gmail.com",
            appPassword: "other-pw",
            host: "imap.gmail.com",
            port: 993
        ))

        XCTAssertEqual(appState.mailEmail, "other@gmail.com")
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertNotNil(appState.backgroundConnectedAccount(email: "me@gmail.com"))
        XCTAssertEqual(appState.pendingDrafts.first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(appState.offlineQueuedDispatch[queuedDraft.identity], intent)
        XCTAssertTrue(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(persistence.loadSettings().mailEmail, "other@gmail.com")
        XCTAssertNil(appState.connectionError)
    }

    func testAccountSwitchSecretFailurePreservesQueuedIntent() async {
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        var queuedDraft = pendingDraft()
        queuedDraft.offlineQueuedDispatch = intent
        let persistence = AppStateMemoryPersistence(
            settings: connectedSettings(),
            pendingDrafts: [queuedDraft]
        )
        let secrets = AppStateFailingSecretStore(seed: [.mailAppPassword: "app-pw"])
        secrets.failOnSet = .mailAppPassword(email: "other@gmail.com")
        let appState = makeTransitionAppState(persistence: persistence, secrets: secrets)

        await appState.testConnection(with: MailAccountCredentials(
            email: "other@gmail.com",
            appPassword: "other-pw",
            host: "imap.gmail.com",
            port: 993
        ))

        XCTAssertEqual(appState.mailEmail, "me@gmail.com")
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(appState.pendingDrafts.first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(appState.offlineQueuedDispatch[queuedDraft.identity], intent)
        XCTAssertTrue(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(persistence.loadSettings().mailEmail, "me@gmail.com")
        XCTAssertTrue(appState.connectionError?.contains("Couldn't save the app password") ?? false)
    }

    func testAccountSwitchSettingsFailurePreservesQueuedIntent() async {
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        var queuedDraft = pendingDraft()
        queuedDraft.offlineQueuedDispatch = intent
        let persistence = AppStateMemoryPersistence(
            settings: connectedSettings(),
            pendingDrafts: [queuedDraft]
        )
        let secrets = InMemorySecretStore(seed: [.mailAppPassword: "app-pw"])
        let appState = makeTransitionAppState(persistence: persistence, secrets: secrets)
        persistence.syncSaveError = AppStatePersistenceError.writeDenied

        await appState.testConnection(with: MailAccountCredentials(
            email: "other@gmail.com",
            appPassword: "other-pw",
            host: "imap.gmail.com",
            port: 993
        ))

        XCTAssertEqual(appState.mailEmail, "me@gmail.com")
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(appState.pendingDrafts.first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(appState.offlineQueuedDispatch[queuedDraft.identity], intent)
        XCTAssertTrue(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(persistence.loadSettings().mailEmail, "me@gmail.com")
        XCTAssertNil(try? secrets.value(for: .mailAppPassword(email: "other@gmail.com")))
        XCTAssertTrue(appState.connectionError?.contains("Couldn't save mailbox settings") ?? false)
    }

    func testDisconnectAbortsWhenQueuedIntentCleanupFails() {
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        var queuedDraft = pendingDraft()
        queuedDraft.offlineQueuedDispatch = intent
        let (appState, _, persistence) = makeAppState(online: false, seed: [queuedDraft])
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        appState.disconnectMail()

        XCTAssertEqual(appState.mailEmail, "me@gmail.com")
        XCTAssertEqual(appState.mailAppPassword, "app-pw")
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(appState.pendingDrafts.first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(appState.offlineQueuedDispatch[queuedDraft.identity], intent)
        XCTAssertTrue(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(persistence.loadSettings().mailEmail, "me@gmail.com")
        XCTAssertTrue(appState.connectionError?.contains("Couldn't clear queued drafts before disconnecting") ?? false)
    }

    func testDisconnectPasswordRemovalFailurePreservesQueuedIntent() {
        let intent = OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        var queuedDraft = pendingDraft()
        queuedDraft.offlineQueuedDispatch = intent
        let persistence = AppStateMemoryPersistence(
            settings: connectedSettings(),
            pendingDrafts: [queuedDraft]
        )
        let secrets = AppStateFailingSecretStore(seed: [.mailAppPassword: "app-pw"])
        secrets.failOnRemove = .mailAppPassword
        let appState = makeTransitionAppState(persistence: persistence, secrets: secrets)

        appState.disconnectMail()

        XCTAssertEqual(appState.mailEmail, "me@gmail.com")
        XCTAssertEqual(appState.mailAppPassword, "app-pw")
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(appState.pendingDrafts.first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(appState.offlineQueuedDispatch[queuedDraft.identity], intent)
        XCTAssertTrue(appState.isWaitingForNetwork(queuedDraft.identity))
        XCTAssertEqual(persistence.loadPendingDrafts().first?.offlineQueuedDispatch, intent)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "app-pw")
        XCTAssertTrue(appState.connectionError?.contains("Couldn't remove the app password") ?? false)
    }
}
