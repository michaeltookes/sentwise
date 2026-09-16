import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateLocalDataPurgeManagedDeleteTests: XCTestCase {

    private let account = "me@gmail.com"

    private func message(id: UInt32, from: String = "alice@x.com") -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: 7,
            from: MailAddress(name: "Alice", email: from),
            subject: "Subject \(id)",
            date: "",
            messageID: "<\(id)@x.com>"
        )
    }

    private func pendingDraft(id: UInt32 = 1) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 10,
            sourceAccountEmail: account,
            sourceMailbox: "INBOX",
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

    private func voiceProfile() -> VoiceProfile {
        VoiceProfile(
            greeting: "Hey,", signOff: "M", formality: "casual", tone: "warm",
            averageLength: "short", commonPhrases: ["Sounds good"], summary: "Warm.",
            sampleCount: 4, generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func skippedMessage() -> SkippedMessage {
        SkippedMessage(
            message: message(id: 2, from: "no-reply@x.com"),
            mailbox: .inbox,
            account: account,
            reason: .noReplySender
        )
    }

    private func activityEvent() -> ActivityEvent {
        ActivityEvent(kind: .draftCreated, account: account, sender: "Alice", subject: "Lunch?")
    }

    private func feedbackRecord() -> DraftFeedbackRecord {
        DraftFeedbackRecord(
            outcome: .approvedAsIs,
            provenance: .watcher,
            answeredNeedsInfo: false,
            draftIdentityHash: DraftFeedbackRecord.hashedIdentity("\(account)|INBOX|10|1"),
            sourceAccountHash: DraftFeedbackRecord.hashedAccount(account)
        )
    }

    private func seededPersistence() -> AppStateMemoryPersistence {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: account, mailbox: .inbox)
        return AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: account,
                mailHost: "imap.gmail.com",
                mailPort: 993,
                savedAccounts: [SavedMailAccount(email: account, host: "imap.gmail.com", port: 993)],
                llmProvider: "anthropic",
                llmVerifiedModel: "claude-sonnet-4-6",
                onboardingCompleted: true
            ),
            voiceProfile: voiceProfile(),
            processedMessages: processed,
            pendingDrafts: [pendingDraft()],
            skippedMessages: [skippedMessage()],
            approvedDraftIdentities: ["\(account)|INBOX|10|99"],
            activityEvents: [activityEvent()],
            draftFeedback: [feedbackRecord()]
        )
    }

    private func makeAppState(
        persistence: AppStateMemoryPersistence,
        secrets: SecretStore = InMemorySecretStore(seed: [.mailAppPassword(email: "me@gmail.com"): "app-pw"]),
        mailProvider: MailProvider = FakeAppMailProvider(result: .success(())),
        llm: LLMProviding = DeletableLLM()
    ) -> (AppState, SecretStore) {
        let app = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: mailProvider,
            llm: llm,
            notifier: FakeDraftNotifier()
        )
        return (app, secrets)
    }

    private func assertAccountArtifactsCleared(
        _ persistence: AppStateMemoryPersistence,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(persistence.loadVoiceProfile(), file: file, line: line)
        XCTAssertFalse(persistence.loadProcessedMessages().hasBaseline(account: account, mailbox: .inbox),
                       file: file, line: line)
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty, file: file, line: line)
        XCTAssertTrue(persistence.loadSkippedMessages().isEmpty, file: file, line: line)
        XCTAssertTrue(persistence.loadApprovedDraftIdentities().isEmpty, file: file, line: line)
        XCTAssertTrue(persistence.loadActivityEvents().isEmpty, file: file, line: line)
        XCTAssertTrue(persistence.loadDraftFeedback().isEmpty, file: file, line: line)
    }

    func testManagedDeleteWithPurgeErasesLocalMailData() async {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "app-pw",
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let (app, _) = makeAppState(persistence: persistence, secrets: secrets)
        app.watchStatus = .watching
        app.recentMessages = [message(id: 99)]
        app.openedBody = MailBodyPreview(id: 99, subject: "Subject 99", text: "cached body")
        app.generatedDraft = pendingDraft(id: 99)

        let ok = await app.deleteManagedAccount(purgeLocalData: true, isHuntMode: false)

        XCTAssertTrue(ok)
        assertAccountArtifactsCleared(persistence)
        XCTAssertEqual(app.watchStatus, .idle)
        XCTAssertTrue(app.recentMessages.isEmpty)
        XCTAssertNil(app.openedBody)
        XCTAssertNil(app.generatedDraft)
        // The mailbox secret survives: deletion targets the Sentwise account, and
        // the purge is scoped to mail content, not credentials.
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: account)), "app-pw")
    }

    func testManagedDeleteWithPurgeRestartsWatcherWhenMailboxCanStillWatch() async {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live",
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let (app, _) = makeAppState(persistence: persistence, secrets: secrets)
        app.watchStatus = .watching

        let ok = await app.deleteManagedAccount(purgeLocalData: true, isHuntMode: false)

        XCTAssertTrue(ok)
        assertAccountArtifactsCleared(persistence)
        XCTAssertEqual(app.watchStatus, .watching)
    }

    func testManagedDeleteWithPurgeFailureRestartsWatcherWhenMailboxCanStillWatch() async {
        let persistence = seededPersistence()
        persistence.purgeError = AppStatePersistenceError.writeDenied
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live",
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let (app, _) = makeAppState(persistence: persistence, secrets: secrets)
        app.watchStatus = .watching

        let ok = await app.deleteManagedAccount(purgeLocalData: true, isHuntMode: false)

        XCTAssertFalse(ok)
        XCTAssertTrue(app.didDeleteManagedAccount)
        XCTAssertFalse(app.isManagedSignedIn)
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertFalse(persistence.loadPendingDrafts().isEmpty)
    }

    func testManagedDeleteRetriesOnlyLocalPurgeAfterRemoteDeleteSucceeded() async {
        let persistence = seededPersistence()
        persistence.purgeError = AppStatePersistenceError.writeDenied
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "app-pw",
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let llm = DeletableLLM()
        let (app, _) = makeAppState(persistence: persistence, secrets: secrets, llm: llm)

        let first = await app.deleteManagedAccount(purgeLocalData: true, isHuntMode: false)
        persistence.purgeError = nil
        let second = await app.deleteManagedAccount(purgeLocalData: true, isHuntMode: false)

        XCTAssertFalse(first)
        XCTAssertTrue(second)
        XCTAssertEqual(llm.deleteCount, 1)
        assertAccountArtifactsCleared(persistence)
    }

    func testManagedDeletePurgeRestartInvalidatesInFlightWatcherDraft() async {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live",
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let incoming = message(id: 55)
        let mailProvider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: .success([incoming]),
            bodyResult: .success(Data("Can you confirm?".utf8))
        )
        let llm = DeletableSuspendedLLM()
        let (app, _) = makeAppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: mailProvider,
            llm: llm
        )
        app.watchStatus = .watching

        let stalePoll = Task {
            await app.pollInboxOnce()
        }
        await fulfillment(of: [llm.didStartCompletion], timeout: 1)

        let ok = await app.deleteManagedAccount(purgeLocalData: true, isHuntMode: false)
        llm.completeDraft(with: .success(LLMResponse(text: "Confirmed.")))
        await stalePoll.value

        XCTAssertTrue(ok)
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertTrue(app.pendingDrafts.isEmpty)
        XCTAssertTrue(persistence.loadPendingDrafts().isEmpty)
        XCTAssertFalse(persistence.loadProcessedMessages().contains(incoming, account: account, mailbox: .inbox))
        XCTAssertTrue(persistence.loadActivityEvents().isEmpty)
    }

    func testManagedDeletePurgeInvalidatesInFlightVoiceLearning() async {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live",
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let mailProvider = FakeAppMailProvider(
            result: .success(()),
            fetchResult: .success([message(id: 70)]),
            bodyResult: .success(Data("Thanks, sounds good.".utf8))
        )
        let llm = DeletableSuspendedLLM()
        let (app, _) = makeAppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: mailProvider,
            llm: llm
        )

        let learning = Task {
            await app.learnVoiceProfile()
        }
        await fulfillment(of: [llm.didStartCompletion], timeout: 1)

        let ok = await app.deleteManagedAccount(purgeLocalData: true, isHuntMode: false)
        let profileJSON = #"""
        {"greeting":"Hi,","signOff":"Best,","formality":"casual","tone":"warm",
         "averageLength":"short","commonPhrases":["Sounds good"],"summary":"Warm and concise."}
        """#
        llm.completeDraft(with: .success(LLMResponse(text: profileJSON)))
        await learning.value

        XCTAssertTrue(ok)
        XCTAssertNil(app.voiceProfile)
        XCTAssertNil(persistence.loadVoiceProfile())
    }

    func testManagedDeleteWithoutPurgeKeepsLocalMailData() async {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let (app, _) = makeAppState(persistence: persistence, secrets: secrets)

        let ok = await app.deleteManagedAccount(purgeLocalData: false, isHuntMode: false)

        XCTAssertTrue(ok)
        XCTAssertNotNil(persistence.loadVoiceProfile())
        XCTAssertFalse(persistence.loadPendingDrafts().isEmpty)
        XCTAssertFalse(persistence.loadActivityEvents().isEmpty)
    }

    func testManagedDeleteWithPurgeErasesRetainedMailDataWhenNoMailboxSelected() async {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "app-pw",
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let (app, _) = makeAppState(persistence: persistence, secrets: secrets)
        let saved = try? XCTUnwrap(app.savedAccounts.first)

        if let saved {
            app.removeSavedAccount(saved, purgeLocalData: false)
        }

        XCTAssertFalse(app.isAccountConnected)
        XCTAssertTrue(app.mailEmail.isEmpty)
        XCTAssertFalse(persistence.loadPendingDrafts().isEmpty)

        let ok = await app.deleteManagedAccount(purgeLocalData: true, isHuntMode: false)

        XCTAssertTrue(ok)
        assertAccountArtifactsCleared(persistence)
    }
}

/// An `LLMProviding` whose `deleteManagedAccount()` succeeds, so the managed-delete
/// purge path can be exercised end to end.
private final class DeletableLLM: LLMProviding, @unchecked Sendable {
    private(set) var deleteCount = 0

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
    func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
        LLMResponse(text: "")
    }
    func deleteManagedAccount() async throws {
        deleteCount += 1
    }
}

private final class DeletableSuspendedLLM: LLMProviding, @unchecked Sendable {
    let didStartCompletion = XCTestExpectation(description: "LLM completion started")
    private let lock = NSLock()
    private var completionContinuation: CheckedContinuation<LLMResponse, Error>?
    private(set) var deleteCount = 0

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            completionContinuation = continuation
            lock.unlock()
            didStartCompletion.fulfill()
        }
    }

    func deleteManagedAccount() async throws {
        deleteCount += 1
    }

    func completeDraft(with result: Result<LLMResponse, Error>) {
        lock.lock()
        let continuation = completionContinuation
        completionContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
