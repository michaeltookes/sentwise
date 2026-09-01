import Foundation

/// In-memory persistence for isolated app runs that must not touch the user's
/// Application Support data. Production app launches use `PersistenceService`.
final class MemoryPersistenceProvider: PersistenceProvider {
    private let lock = NSLock()
    private var settings: Settings
    private var voiceProfile: VoiceProfile?
    private var processedMessages: ProcessedMessages
    private var pendingDrafts: [Draft]
    private var skippedMessages: [SkippedMessage]
    private var approvedDraftIdentities: Set<String>
    private var activityEvents: [ActivityEvent]
    private var draftFeedback: [DraftFeedbackRecord]

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
        self.settings = settings.validated()
        self.voiceProfile = voiceProfile
        self.processedMessages = processedMessages
        self.pendingDrafts = pendingDrafts
        self.skippedMessages = skippedMessages
        self.approvedDraftIdentities = approvedDraftIdentities
        self.activityEvents = activityEvents
        self.draftFeedback = draftFeedback
    }

    func loadSettings() -> Settings {
        withLock { settings }
    }

    func saveSettings(_ settings: Settings) {
        withLock {
            self.settings = settings.validated()
        }
    }

    func saveSettingsSync(_ settings: Settings) throws {
        saveSettings(settings)
    }

    func loadVoiceProfile() -> VoiceProfile? {
        withLock { voiceProfile }
    }

    func saveVoiceProfile(_ profile: VoiceProfile) {
        withLock {
            voiceProfile = profile
        }
    }

    func removeVoiceProfile() {
        withLock {
            voiceProfile = nil
        }
    }

    func loadProcessedMessages() -> ProcessedMessages {
        withLock { processedMessages }
    }

    func saveProcessedMessages(_ processed: ProcessedMessages) {
        withLock {
            processedMessages = processed
        }
    }

    func loadPendingDrafts() -> [Draft] {
        withLock { pendingDrafts }
    }

    func savePendingDraftsSync(_ drafts: [Draft]) throws {
        withLock {
            pendingDrafts = drafts
        }
    }

    func loadSkippedMessages() -> [SkippedMessage] {
        withLock { skippedMessages }
    }

    func saveSkippedMessagesSync(_ messages: [SkippedMessage]) throws {
        withLock {
            skippedMessages = messages
        }
    }

    func loadApprovedDraftIdentities() -> Set<String> {
        withLock { approvedDraftIdentities }
    }

    func saveApprovedDraftIdentitiesSync(_ identities: Set<String>) throws {
        withLock {
            approvedDraftIdentities = identities
        }
    }

    func loadActivityEvents() -> [ActivityEvent] {
        withLock { activityEvents }
    }

    func saveActivityEvents(_ events: [ActivityEvent]) {
        withLock {
            activityEvents = events
        }
    }

    func loadDraftFeedback() -> [DraftFeedbackRecord] {
        withLock { draftFeedback }
    }

    func saveDraftFeedback(_ records: [DraftFeedbackRecord]) {
        withLock {
            draftFeedback = records
        }
    }

    private func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
