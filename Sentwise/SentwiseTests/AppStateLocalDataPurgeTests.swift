import SentwiseMail
import Security
import XCTest
@testable import Sentwise

/// Tests for local-data purge and full erase (item 96 / security finding A-L2):
/// per-artifact purge on disconnect / account removal / managed-account deletion,
/// the "Erase all local data" action, the dedup re-add decision, and hunt-mode /
/// seam safety (no work bypasses the persistence provider).
@MainActor
final class AppStateLocalDataPurgeTests: XCTestCase {

    // MARK: - Fixtures

    private let account = "me@gmail.com"
    private let otherAccount = "other@gmail.com"

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

    private func pendingDraft(id: UInt32 = 1, account: String? = nil) -> Draft {
        let account = account ?? self.account
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
        skippedMessage(account: account)
    }

    private func skippedMessage(account: String) -> SkippedMessage {
        SkippedMessage(
            message: message(id: 2, from: "no-reply@x.com"),
            mailbox: .inbox,
            account: account,
            reason: .noReplySender
        )
    }

    private func activityEvent(account: String? = nil) -> ActivityEvent {
        ActivityEvent(kind: .draftCreated, account: account ?? self.account, sender: "Alice", subject: "Lunch?")
    }

    private func feedbackRecord(account: String? = nil) -> DraftFeedbackRecord {
        let account = account ?? self.account
        DraftFeedbackRecord(
            outcome: .approvedAsIs,
            provenance: .watcher,
            answeredNeedsInfo: false,
            draftIdentityHash: DraftFeedbackRecord.hashedIdentity("\(account)|INBOX|10|1"),
            sourceAccountEmail: account
        )
    }

    /// A persistence store seeded with every account-scoped artifact populated,
    /// plus a watcher baseline in the dedup set.
    private func seededPersistence(mailEmail: String = "me@gmail.com") -> AppStateMemoryPersistence {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: mailEmail, mailbox: .inbox)
        return AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: mailEmail,
                mailHost: "imap.gmail.com",
                mailPort: 993,
                savedAccounts: [SavedMailAccount(email: mailEmail, host: "imap.gmail.com", port: 993)],
                onboardingCompleted: true
            ),
            voiceProfile: voiceProfile(),
            processedMessages: processed,
            pendingDrafts: [pendingDraft()],
            skippedMessages: [skippedMessage()],
            approvedDraftIdentities: ["\(mailEmail)|INBOX|10|1"],
            activityEvents: [activityEvent(account: mailEmail)],
            draftFeedback: [feedbackRecord()]
        )
    }

    private func seededMultiAccountPersistence() -> AppStateMemoryPersistence {
        var processed = ProcessedMessages()
        processed.insertBaseline(account: account, mailbox: .inbox)
        processed.insertBaseline(account: otherAccount, mailbox: .inbox)
        return AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: account,
                mailHost: "imap.gmail.com",
                mailPort: 993,
                savedAccounts: [
                    SavedMailAccount(email: account, host: "imap.gmail.com", port: 993),
                    SavedMailAccount(email: otherAccount, host: "imap.gmail.com", port: 993)
                ],
                onboardingCompleted: true
            ),
            voiceProfile: voiceProfile(),
            processedMessages: processed,
            pendingDrafts: [pendingDraft(id: 1, account: account), pendingDraft(id: 2, account: otherAccount)],
            skippedMessages: [skippedMessage(account: account), skippedMessage(account: otherAccount)],
            approvedDraftIdentities: ["\(account)|INBOX|10|1", "\(otherAccount)|INBOX|10|2"],
            activityEvents: [activityEvent(account: account), activityEvent(account: otherAccount)],
            draftFeedback: [feedbackRecord(account: account), feedbackRecord(account: otherAccount)]
        )
    }

    private func makeAppState(
        persistence: AppStateMemoryPersistence,
        secrets: SecretStore = InMemorySecretStore(seed: [.mailAppPassword(email: "me@gmail.com"): "app-pw"]),
        notifier: FakeDraftNotifier = FakeDraftNotifier(),
        llm: LLMProviding = FakeLLMProvider(result: .success(()))
    ) -> (AppState, FakeDraftNotifier, SecretStore) {
        let app = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: notifier
        )
        return (app, notifier, secrets)
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

    private func assertOtherAccountArtifactsPreserved(
        _ persistence: AppStateMemoryPersistence,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(persistence.loadProcessedMessages().hasBaseline(account: otherAccount, mailbox: .inbox),
                      file: file, line: line)
        XCTAssertEqual(persistence.loadPendingDrafts().compactMap(\.sourceAccountEmail), [otherAccount],
                       file: file, line: line)
        XCTAssertEqual(persistence.loadSkippedMessages().map(\.account), [otherAccount], file: file, line: line)
        XCTAssertEqual(persistence.loadApprovedDraftIdentities(), ["\(otherAccount)|INBOX|10|2"],
                       file: file, line: line)
        XCTAssertEqual(persistence.loadActivityEvents().compactMap(\.account), [otherAccount], file: file, line: line)
        XCTAssertEqual(persistence.loadDraftFeedback().compactMap(\.sourceAccountEmail), [otherAccount],
                       file: file, line: line)
    }

    // MARK: - Per-artifact purge

    func testPurgeRemovesEveryAccountScopedArtifactFromDisk() throws {
        let persistence = seededPersistence()
        let (app, _, _) = makeAppState(persistence: persistence)

        try app.purgeLocalMailArtifacts()

        assertAccountArtifactsCleared(persistence)
        XCTAssertEqual(persistence.removedArtifacts, ["voice"])
    }

    func testPurgeClearsInMemoryState() throws {
        let persistence = seededPersistence()
        let (app, _, _) = makeAppState(persistence: persistence)
        // Confirm the launch actually loaded the seeded state into memory first.
        XCTAssertFalse(app.pendingDrafts.isEmpty)
        XCTAssertFalse(app.activityEvents.isEmpty)

        try app.purgeLocalMailArtifacts()

        XCTAssertNil(app.voiceProfile)
        XCTAssertTrue(app.pendingDrafts.isEmpty)
        XCTAssertEqual(app.pendingDraftCount, 0)
        XCTAssertTrue(app.skippedMessages.isEmpty)
        XCTAssertTrue(app.activityEvents.isEmpty)
        XCTAssertTrue(app.draftFeedbackRecords.isEmpty)
        XCTAssertFalse(app.processedMessages.hasBaseline(account: account, mailbox: .inbox))
    }

    func testPurgeRemovesPendingDraftNotifications() throws {
        let persistence = seededPersistence()
        let notifier = FakeDraftNotifier()
        let (app, _, _) = makeAppState(persistence: persistence, notifier: notifier)
        let expected = app.pendingDrafts.first?.identity

        try app.purgeLocalMailArtifacts()

        XCTAssertEqual(notifier.removedIdentities, [expected].compactMap { $0 })
    }

    func testPurgeLeavesSettingsAndKeychainIntact() throws {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [.mailAppPassword(email: account): "app-pw"])
        let (app, _, _) = makeAppState(persistence: persistence, secrets: secrets)

        try app.purgeLocalMailArtifacts()

        // Settings file untouched (never sent through eraseAll) and the Keychain
        // secret survives, so a same-account reconnect still works.
        XCTAssertEqual(persistence.eraseAllCount, 0)
        XCTAssertEqual(persistence.loadSettings().mailEmail, account)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: account)), "app-pw")
    }

    func testRemovingInactiveSavedAccountPurgesOnlyThatAccountArtifacts() {
        let persistence = seededMultiAccountPersistence()
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "active-pw",
            .mailAppPassword(email: otherAccount): "other-pw"
        ])
        let (app, _, _) = makeAppState(persistence: persistence, secrets: secrets)
        let saved = app.savedAccounts.first { $0.id == SavedMailAccount.normalizedEmail(otherAccount) }

        if let saved { app.removeSavedAccount(saved, purgeLocalData: true) }

        XCTAssertNotNil(persistence.loadVoiceProfile())
        XCTAssertTrue(persistence.loadProcessedMessages().hasBaseline(account: account, mailbox: .inbox))
        XCTAssertFalse(persistence.loadProcessedMessages().hasBaseline(account: otherAccount, mailbox: .inbox))
        XCTAssertEqual(persistence.loadPendingDrafts().compactMap(\.sourceAccountEmail), [account])
        XCTAssertEqual(persistence.loadSkippedMessages().map(\.account), [account])
        XCTAssertEqual(persistence.loadApprovedDraftIdentities(), ["\(account)|INBOX|10|1"])
        XCTAssertEqual(persistence.loadActivityEvents().compactMap(\.account), [account])
        XCTAssertEqual(persistence.loadDraftFeedback().compactMap(\.sourceAccountEmail), [account])
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: account)), "active-pw")
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: otherAccount))) ?? nil)
    }

    // MARK: - Disconnect

    func testDisconnectWithPurgeErasesData() {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [.mailAppPassword(email: account): "app-pw"])
        let (app, _, _) = makeAppState(persistence: persistence, secrets: secrets)
        XCTAssertTrue(app.isAccountConnected)

        app.disconnectMail(purgeLocalData: true)

        XCTAssertFalse(app.isAccountConnected)
        assertAccountArtifactsCleared(persistence)
    }

    func testDisconnectWithoutPurgeKeepsData() {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [.mailAppPassword(email: account): "app-pw"])
        let (app, _, _) = makeAppState(persistence: persistence, secrets: secrets)

        app.disconnectMail(purgeLocalData: false)

        XCTAssertFalse(app.isAccountConnected)
        // Mail content is deliberately preserved for a friction-free reconnect.
        XCTAssertNotNil(persistence.loadVoiceProfile())
        XCTAssertFalse(persistence.loadPendingDrafts().isEmpty)
        XCTAssertFalse(persistence.loadActivityEvents().isEmpty)
    }

    // MARK: - Remove saved account

    func testRemoveSavedAccountWithPurgeErasesData() {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [.mailAppPassword(email: account): "app-pw"])
        let (app, _, _) = makeAppState(persistence: persistence, secrets: secrets)
        let saved = try? XCTUnwrap(app.savedAccounts.first)

        if let saved { app.removeSavedAccount(saved, purgeLocalData: true) }

        assertAccountArtifactsCleared(persistence)
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: account))) ?? nil)
    }

    func testRemoveSavedAccountWithoutPurgeKeepsData() {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [.mailAppPassword(email: account): "app-pw"])
        let (app, _, _) = makeAppState(persistence: persistence, secrets: secrets)
        let saved = try? XCTUnwrap(app.savedAccounts.first)

        if let saved { app.removeSavedAccount(saved, purgeLocalData: false) }

        XCTAssertNotNil(persistence.loadVoiceProfile())
        XCTAssertFalse(persistence.loadPendingDrafts().isEmpty)
    }

    // MARK: - Dedup re-add decision

    /// The recommended decision: purge the dedup with the account. After a purge the
    /// watcher baseline is gone, so the watcher re-seeds a fresh baseline on the next
    /// connect (existing inbox mail becomes historical) rather than re-drafting it.
    func testPurgeClearsWatcherBaselineSoReconnectReseeds() throws {
        let persistence = seededPersistence()
        let (app, _, _) = makeAppState(persistence: persistence)
        XCTAssertTrue(persistence.loadProcessedMessages().hasBaseline(account: account, mailbox: .inbox))

        try app.purgeLocalMailArtifacts()

        // No baseline and no dedup means the next poll seeds a new baseline; the
        // watcher's baseline filter treats current inbox mail as historical.
        let reloaded = persistence.loadProcessedMessages()
        XCTAssertFalse(reloaded.hasBaseline(account: account, mailbox: .inbox))
        XCTAssertFalse(app.processedMessages.hasBaseline(account: account, mailbox: .inbox))
    }

    // MARK: - Erase all local data

    func testEraseAllWipesEverythingClearsKeychainAndResetsToFirstRun() async {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "app-pw",
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let (app, _, _) = makeAppState(persistence: persistence, secrets: secrets)

        let result = await app.eraseAllLocalData()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(persistence.eraseAllCount, 1)
        // Every Keychain item is gone.
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: account))) ?? nil)
        XCTAssertNil((try? secrets.value(for: .managedClientToken)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .managedSessionID)) ?? nil)
        // In-memory state is back to first-run.
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertTrue(app.savedAccounts.isEmpty)
        XCTAssertTrue(app.mailEmail.isEmpty)
        XCTAssertFalse(app.isManagedSignedIn)
        XCTAssertFalse(app.onboardingCompleted)
        XCTAssertNil(app.voiceProfile)
        XCTAssertTrue(app.pendingDrafts.isEmpty)
        XCTAssertTrue(app.activityEvents.isEmpty)
    }

    func testEraseAllReturnsFalseWhenKeychainWipeFails() async {
        let persistence = seededPersistence()
        let secrets = ThrowingRemoveAllSecretStore()
        let (app, _, _) = makeAppState(persistence: persistence, secrets: secrets)

        let result = await app.eraseAllLocalData()

        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(result.keychainError)
        // On-disk + in-memory wipe still happened despite the Keychain failure.
        XCTAssertEqual(persistence.eraseAllCount, 1)
        XCTAssertTrue(app.pendingDrafts.isEmpty)
        XCTAssertFalse(app.onboardingCompleted)
    }

    // MARK: - Managed-account deletion purge offer

    func testManagedDeleteWithPurgeErasesLocalMailData() async {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account): "app-pw",
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let (app, _, _) = makeAppState(persistence: persistence, secrets: secrets, llm: DeletableLLM())

        let ok = await app.deleteManagedAccount(purgeLocalData: true, isHuntMode: false)

        XCTAssertTrue(ok)
        assertAccountArtifactsCleared(persistence)
        // The mailbox secret survives — deletion targets the Sentwise account, and
        // the purge is scoped to mail *content*, not credentials.
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: account)), "app-pw")
    }

    func testManagedDeleteWithoutPurgeKeepsLocalMailData() async {
        let persistence = seededPersistence()
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client",
            .managedSessionID: "sess"
        ])
        let (app, _, _) = makeAppState(persistence: persistence, secrets: secrets, llm: DeletableLLM())

        let ok = await app.deleteManagedAccount(purgeLocalData: false, isHuntMode: false)

        XCTAssertTrue(ok)
        XCTAssertNotNil(persistence.loadVoiceProfile())
        XCTAssertFalse(persistence.loadPendingDrafts().isEmpty)
        XCTAssertFalse(persistence.loadActivityEvents().isEmpty)
    }

    // MARK: - Hunt-mode / seam safety

    /// In hunt mode the persistence provider is the in-memory `MemoryPersistenceProvider`
    /// and the secret store is in-memory, so purge and erase touch zero disk — they
    /// only mutate the seam. This exercises the same provider hunts use.
    func testPurgeAndEraseAreDiskFreeThroughMemoryProvider() {
        let provider = MemoryPersistenceProvider(
            settings: .default,
            voiceProfile: voiceProfile(),
            pendingDrafts: [pendingDraft()],
            activityEvents: [activityEvent()],
            draftFeedback: [feedbackRecord()]
        )

        try? provider.purgeAccountScopedArtifacts(for: account, includeUnscopedArtifacts: true)
        XCTAssertNil(provider.loadVoiceProfile())
        XCTAssertTrue(provider.loadPendingDrafts().isEmpty)
        XCTAssertTrue(provider.loadActivityEvents().isEmpty)
        XCTAssertTrue(provider.loadDraftFeedback().isEmpty)

        try? provider.eraseAllLocalData()
        XCTAssertEqual(provider.loadSettings(), Settings.default.validated())
    }
}

/// An `LLMProviding` whose `deleteManagedAccount()` succeeds, so the managed-delete
/// purge path can be exercised end to end.
private final class DeletableLLM: LLMProviding, @unchecked Sendable {
    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
    func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
        LLMResponse(text: "")
    }
    func deleteManagedAccount() async throws {}
}

/// A `SecretStore` whose `removeAll()` always throws, to drive the erase-all
/// Keychain-failure path.
private final class ThrowingRemoveAllSecretStore: SecretStore {
    private var storage: [String: String] = [
        SecretKey.mailAppPassword(email: "me@gmail.com").rawValue: "app-pw"
    ]

    func set(_ value: String, for key: SecretKey) throws { storage[key.rawValue] = value }
    func value(for key: SecretKey) throws -> String? { storage[key.rawValue] }
    func remove(_ key: SecretKey) throws { storage[key.rawValue] = nil }
    func removeAll() throws { throw KeychainError.unexpectedStatus(errSecInternalError) }
}
