import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateConnectTransitionFeedbackTests: XCTestCase {

    private func draft(id: UInt32 = 1, account: String) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: account,
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: "Question",
            sourceFrom: MailAddress(name: "Alice", email: "alice@example.com"),
            sourceReplyTo: nil,
            sourceMessageID: "<\(id)@example.com>",
            incomingBody: "Can you help?",
            replySubject: "Re: Question",
            body: "Sure.",
            model: "claude-sonnet-4-6",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            offlineQueuedDispatch: OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        )
    }

    func testReconnectFromEmptyFocusedSlotRemovesDuplicateBackgroundRuntime() async {
        let account = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "",
            savedAccounts: [account],
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account.email): "gmail-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let app = AppState(
            persistence: AppStateMemoryPersistence(settings: settings),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        app.backgroundConnectedAccounts = [
            ConnectedMailAccount(
                email: account.email,
                host: account.host,
                port: account.port,
                appPassword: "gmail-pw"
            )
        ]

        await app.testConnection(with: MailAccountCredentials(
            email: account.email,
            appPassword: "gmail-pw",
            host: account.host,
            port: account.port
        ))

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, account.email)
        XCTAssertTrue(app.backgroundConnectedAccounts.isEmpty)
        XCTAssertEqual(app.connectedAccountCount, 1)
    }

    func testPromotingBackgroundAccountPreservesItsWatcherState() async {
        let focused = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let target = SavedMailAccount(email: "side@work.com", host: "imap.work.com", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: focused.email,
            savedAccounts: [focused, target],
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: focused.email): "focused-pw",
            .mailAppPassword(email: target.email): "target-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let app = AppState(
            persistence: AppStateMemoryPersistence(settings: settings),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(()), fetchResult: .success([])),
            llm: FakeLLMProvider(result: .success(())),
            reachability: FakeReachabilityMonitor()
        )
        app.mailAppPassword = "focused-pw"
        app.watchStatus = .paused
        app.watchError = "Focused auth failed"
        app.resumeWatchingAfterManagedReauth = true
        let background = ConnectedMailAccount(
            email: target.email,
            host: target.host,
            port: target.port,
            appPassword: "target-pw"
        )
        background.watchStatus = .watching
        app.backgroundConnectedAccounts = [background]

        await app.testConnection(with: MailAccountCredentials(
            email: target.email,
            appPassword: "target-pw",
            host: target.host,
            port: target.port
        ))

        XCTAssertEqual(app.mailEmail, target.email)
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertNil(app.watchError)
        XCTAssertFalse(app.resumeWatchingAfterManagedReauth)
        let demoted = app.backgroundConnectedAccount(email: focused.email)
        XCTAssertEqual(demoted?.watchStatus, .paused)
        XCTAssertEqual(demoted?.watchError, "Focused auth failed")
        XCTAssertEqual(demoted?.resumeWatchingAfterManagedReauth, true)
        app.stopWatching()
    }

    func testPromotingPausedBackgroundAccountKeepsItsHealthState() async {
        let focused = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let target = SavedMailAccount(email: "side@work.com", host: "imap.work.com", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: focused.email,
            savedAccounts: [focused, target],
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: focused.email): "focused-pw",
            .mailAppPassword(email: target.email): "target-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let app = AppState(
            persistence: AppStateMemoryPersistence(settings: settings),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(()), fetchResult: .success([])),
            llm: FakeLLMProvider(result: .success(())),
            reachability: FakeReachabilityMonitor()
        )
        app.mailAppPassword = "focused-pw"
        app.watchStatus = .watching
        let background = ConnectedMailAccount(
            email: target.email,
            host: target.host,
            port: target.port,
            appPassword: "target-pw"
        )
        background.watchStatus = .paused
        background.watchError = "Target auth failed"
        background.resumeWatchingAfterManagedReauth = true
        app.backgroundConnectedAccounts = [background]

        await app.testConnection(with: MailAccountCredentials(
            email: target.email,
            appPassword: "target-pw",
            host: target.host,
            port: target.port
        ))

        XCTAssertEqual(app.watchStatus, .paused)
        XCTAssertEqual(app.watchError, "Target auth failed")
        XCTAssertTrue(app.resumeWatchingAfterManagedReauth)
        XCTAssertEqual(app.backgroundConnectedAccount(email: focused.email)?.watchStatus, .watching)
        app.stopAllBackgroundWatchers()
    }

    func testFocusChangeKeepsOfflineDispatchIntentForRetainedBackgroundAccount() async {
        let focused = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let target = SavedMailAccount(email: "side@work.com", host: "imap.work.com", port: 993)
        let queuedDraft = draft(account: target.email)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: focused.email,
            savedAccounts: [focused, target],
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        )
        let persistence = AppStateMemoryPersistence(settings: settings, pendingDrafts: [queuedDraft])
        let app = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore(seed: [
                .mailAppPassword(email: focused.email): "focused-pw",
                .mailAppPassword(email: target.email): "target-pw",
                .llmAPIKey(provider: "anthropic"): "sk-live"
            ]),
            mailProvider: FakeAppMailProvider(result: .success(()), fetchResult: .success([])),
            llm: FakeLLMProvider(result: .success(())),
            reachability: FakeReachabilityMonitor()
        )
        app.mailAppPassword = "focused-pw"
        app.offlineQueuedDispatch = AppState.offlineQueuedDispatches(from: [queuedDraft])
        app.draftsWaitingForNetwork = [queuedDraft.identity]
        app.backgroundConnectedAccounts = [
            ConnectedMailAccount(
                email: target.email,
                host: target.host,
                port: target.port,
                appPassword: "target-pw"
            )
        ]

        await app.testConnection(with: MailAccountCredentials(
            email: target.email,
            appPassword: "target-pw",
            host: target.host,
            port: target.port
        ))

        XCTAssertEqual(
            app.offlineQueuedDispatch[queuedDraft.identity],
            OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        )
        XCTAssertTrue(app.draftsWaitingForNetwork.contains(queuedDraft.identity))
        XCTAssertEqual(
            persistence.loadPendingDrafts().first?.offlineQueuedDispatch,
            OfflineQueuedDraftDispatch(sendBehavior: .autoSend)
        )
    }
}
