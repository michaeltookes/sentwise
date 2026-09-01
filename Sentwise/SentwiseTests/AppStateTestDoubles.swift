import SentwiseMail
import Security
import XCTest
@testable import Sentwise

final class AppStateMemoryPersistence: PersistenceProvider {
    private var settings: Settings
    private(set) var voiceProfile: VoiceProfile?
    private(set) var processedMessages: ProcessedMessages
    private(set) var pendingDrafts: [Draft]
    private(set) var skippedMessages: [SkippedMessage]
    private(set) var approvedDraftIdentities: Set<String>
    private(set) var activityEvents: [ActivityEvent]
    private(set) var draftFeedback: [DraftFeedbackRecord]
    private(set) var draftFeedbackSaveCount = 0
    private(set) var settingsSaveCount = 0
    private(set) var savedSettingsHistory: [Settings] = []
    private(set) var processedSaveCount = 0
    private(set) var pendingDraftSaveCount = 0
    private(set) var skippedMessageSaveCount = 0
    private(set) var approvedDraftSaveCount = 0
    private(set) var activityEventSaveCount = 0
    private(set) var saveEvents: [String] = []
    var syncSaveError: Error?
    var pendingDraftSaveError: Error?
    var skippedMessageSaveError: Error?
    var approvedDraftSaveError: Error?

    init(
        settings: Settings = .default,
        voiceProfile: VoiceProfile? = nil,
        processedMessages: ProcessedMessages = ProcessedMessages(),
        pendingDrafts: [Draft] = [],
        skippedMessages: [SkippedMessage] = [],
        approvedDraftIdentities: Set<String> = [],
        activityEvents: [ActivityEvent] = [],
        draftFeedback: [DraftFeedbackRecord] = []
    ) {
        self.settings = settings
        self.voiceProfile = voiceProfile
        self.processedMessages = processedMessages
        self.pendingDrafts = pendingDrafts
        self.skippedMessages = skippedMessages
        self.approvedDraftIdentities = approvedDraftIdentities
        self.activityEvents = activityEvents
        self.draftFeedback = draftFeedback
    }

    func loadSettings() -> Settings { settings }
    func saveSettings(_ settings: Settings) {
        self.settings = settings
        settingsSaveCount += 1
        savedSettingsHistory.append(settings)
    }
    func saveSettingsSync(_ settings: Settings) throws {
        if let syncSaveError {
            throw syncSaveError
        }
        self.settings = settings
        settingsSaveCount += 1
        savedSettingsHistory.append(settings)
    }

    func loadVoiceProfile() -> VoiceProfile? { voiceProfile }
    func saveVoiceProfile(_ profile: VoiceProfile) { voiceProfile = profile }
    func removeVoiceProfile() { voiceProfile = nil }

    func loadProcessedMessages() -> ProcessedMessages { processedMessages }
    func saveProcessedMessages(_ processed: ProcessedMessages) {
        processedMessages = processed
        processedSaveCount += 1
        saveEvents.append("processed")
    }

    func loadPendingDrafts() -> [Draft] { pendingDrafts }
    func savePendingDraftsSync(_ drafts: [Draft]) throws {
        if let pendingDraftSaveError {
            throw pendingDraftSaveError
        }
        pendingDrafts = drafts
        pendingDraftSaveCount += 1
        saveEvents.append("pending")
    }

    func loadSkippedMessages() -> [SkippedMessage] { skippedMessages }
    func saveSkippedMessagesSync(_ messages: [SkippedMessage]) throws {
        if let skippedMessageSaveError {
            throw skippedMessageSaveError
        }
        skippedMessages = messages
        skippedMessageSaveCount += 1
    }

    func loadApprovedDraftIdentities() -> Set<String> { approvedDraftIdentities }
    func saveApprovedDraftIdentitiesSync(_ identities: Set<String>) throws {
        if let approvedDraftSaveError {
            throw approvedDraftSaveError
        }
        approvedDraftIdentities = identities
        approvedDraftSaveCount += 1
        saveEvents.append("approved")
    }

    func loadActivityEvents() -> [ActivityEvent] { activityEvents }
    // Deliberately does not append to `saveEvents`: the activity log is an
    // additive side effect, so ordering assertions on the core save sequence
    // (pending/processed/approved) stay stable.
    func saveActivityEvents(_ events: [ActivityEvent]) {
        activityEvents = events
        activityEventSaveCount += 1
    }

    func loadDraftFeedback() -> [DraftFeedbackRecord] { draftFeedback }
    // Like the activity log, the feedback store is an additive side effect and is
    // deliberately left out of `saveEvents` so core save-order assertions hold.
    func saveDraftFeedback(_ records: [DraftFeedbackRecord]) {
        draftFeedback = records
        draftFeedbackSaveCount += 1
    }
}

enum AppStatePersistenceError: LocalizedError {
    case writeDenied

    var errorDescription: String? {
        switch self {
        case .writeDenied:
            return "settings write denied"
        }
    }
}

final class FakeAppMailProvider: MailProvider, @unchecked Sendable {
    private let result: Result<Void, MailError>
    private let fetchResult: Result<[MailMessage], MailError>
    private let bodyResult: Result<Data, MailError>
    private let headerResult: Result<MailHeaderFields, MailError>
    private let appendResult: Result<Void, MailError>
    private let sendResult: Result<Void, MailError>
    private(set) var lastCredentials: MailAccountCredentials?
    private(set) var fetchCallCount = 0
    private(set) var bodyFetchCallCount = 0
    private(set) var headerFetchCallCount = 0
    private(set) var lastBodyUID: UInt32?
    private(set) var lastHeaderUID: UInt32?
    private(set) var lastExpectedUIDValidity: UInt32?
    private(set) var appendedMailbox: Mailbox?
    private(set) var appendedRFC822: Data?
    private(set) var appendedFlags: [MailFlag]?
    private(set) var sentRFC822: Data?
    private(set) var sentEnvelope: SMTPEnvelope?
    private(set) var sendCallCount = 0

    init(
        result: Result<Void, MailError>,
        fetchResult: Result<[MailMessage], MailError> = .success([]),
        bodyResult: Result<Data, MailError> = .success(Data()),
        headerResult: Result<MailHeaderFields, MailError> = .success(MailHeaderFields()),
        appendResult: Result<Void, MailError> = .success(()),
        sendResult: Result<Void, MailError> = .success(())
    ) {
        self.result = result
        self.fetchResult = fetchResult
        self.bodyResult = bodyResult
        self.headerResult = headerResult
        self.appendResult = appendResult
        self.sendResult = sendResult
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        lastCredentials = credentials
        try result.get()
    }

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        fetchCallCount += 1
        return try fetchResult.get()
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        bodyFetchCallCount += 1
        lastBodyUID = uid
        lastExpectedUIDValidity = expectedUIDValidity
        return try bodyResult.get()
    }

    func fetchHeaderFields(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> MailHeaderFields {
        headerFetchCallCount += 1
        lastHeaderUID = uid
        return try headerResult.get()
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {
        appendedMailbox = mailbox
        appendedRFC822 = rfc822
        appendedFlags = flags
        try appendResult.get()
    }

    func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws {
        sendCallCount += 1
        sentRFC822 = rfc822
        sentEnvelope = envelope
        try sendResult.get()
    }
}

final class SuspendedAppMailProvider: MailProvider, @unchecked Sendable {
    let didStartVerification = XCTestExpectation(description: "mail verification started")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var lastCredentials: MailAccountCredentials?

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            lastCredentials = credentials
            self.continuation = continuation
            lock.unlock()
            didStartVerification.fulfill()
        }
    }

    func complete(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, limit: Int
    ) async throws -> [MailMessage] { [] }

    func fetchBodyText(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, uid: UInt32, expectedUIDValidity: UInt32?
    ) async throws -> Data { Data() }

    func appendMessage(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, rfc822: Data, flags: [MailFlag]
    ) async throws {}
}

final class SuspendedSendMailProvider: MailProvider, @unchecked Sendable {
    let didStartSend = XCTestExpectation(description: "mail send started")
    private let lock = NSLock()
    private var sendContinuation: CheckedContinuation<Void, Error>?
    private var sendCount = 0
    private var capturedEnvelope: SMTPEnvelope?

    var sentMessageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sendCount
    }

    var sentEnvelope: SMTPEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return capturedEnvelope
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, limit: Int
    ) async throws -> [MailMessage] { [] }

    func fetchBodyText(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, uid: UInt32, expectedUIDValidity: UInt32?
    ) async throws -> Data { Data() }

    func appendMessage(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, rfc822: Data, flags: [MailFlag]
    ) async throws {}

    func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            sendCount += 1
            capturedEnvelope = envelope
            sendContinuation = continuation
            lock.unlock()
            didStartSend.fulfill()
        }
    }

    func completeSend(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = sendContinuation
        sendContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

final class SuspendedBodyMailProvider: MailProvider, @unchecked Sendable {
    let didStartBodyFetch = XCTestExpectation(description: "body fetch started")
    private let lock = NSLock()
    private var bodyContinuation: CheckedContinuation<Data, Error>?
    private(set) var lastCredentials: MailAccountCredentials?

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, limit: Int
    ) async throws -> [MailMessage] { [] }

    func fetchBodyText(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, uid: UInt32, expectedUIDValidity: UInt32?
    ) async throws -> Data {
        lock.lock()
        lastCredentials = credentials
        lock.unlock()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            bodyContinuation = continuation
            lock.unlock()
            didStartBodyFetch.fulfill()
        }
    }

    func completeBody(with result: Result<Data, Error>) {
        lock.lock()
        let continuation = bodyContinuation
        bodyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func appendMessage(
        _ credentials: MailAccountCredentials, mailbox: Mailbox, rfc822: Data, flags: [MailFlag]
    ) async throws {}
}

final class AppStateFailingSecretStore: SecretStore {
    var failOnSet: SecretKey?
    var failOnRemove: SecretKey?
    private var storage: [String: String]

    init(seed: [SecretKey: String] = [:]) {
        storage = seed.reduce(into: [:]) { result, item in
            result[item.key.rawValue] = item.value
        }
    }

    func set(_ value: String, for key: SecretKey) throws {
        if failOnSet == key {
            throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        }
        storage[key.rawValue] = value
    }

    func value(for key: SecretKey) throws -> String? {
        storage[key.rawValue]
    }

    func remove(_ key: SecretKey) throws {
        if failOnRemove == key {
            throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
        }
        storage[key.rawValue] = nil
    }

    func removeAll() throws {
        storage.removeAll()
    }
}
