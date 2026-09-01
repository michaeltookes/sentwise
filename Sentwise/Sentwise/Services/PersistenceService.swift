import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "Persistence")

/// Persistence operations used by `AppState`.
///
/// An in-memory implementation can be substituted in tests so they never
/// touch real disk. Secrets (OAuth tokens, API keys) are **not** stored here —
/// those go through the Keychain in a later milestone.
protocol PersistenceProvider {
    func loadSettings() -> Settings
    func saveSettings(_ settings: Settings)
    func saveSettingsSync(_ settings: Settings) throws

    /// The stored voice profile, or `nil` if the user hasn't learned one yet.
    func loadVoiceProfile() -> VoiceProfile?
    /// Persists the voice profile (replaces any existing one).
    func saveVoiceProfile(_ profile: VoiceProfile)
    /// Removes the stored voice profile.
    func removeVoiceProfile()

    /// The set of inbox messages the watcher has already processed.
    func loadProcessedMessages() -> ProcessedMessages
    /// Persists the processed-message set (replaces the previous one).
    func saveProcessedMessages(_ processed: ProcessedMessages)

    /// Watcher-created drafts awaiting approval.
    func loadPendingDrafts() -> [Draft]
    /// Persists watcher-created drafts before their source messages are marked processed.
    func savePendingDraftsSync(_ drafts: [Draft]) throws

    /// Recoverable reply-worthiness skips visible in the Review window.
    func loadSkippedMessages() -> [SkippedMessage]
    /// Persists recoverable skips before source drafts are removed.
    func saveSkippedMessagesSync(_ messages: [SkippedMessage]) throws

    /// Identities of drafts whose approve action completed.
    func loadApprovedDraftIdentities() -> Set<String>
    /// Persists completed approve identities before pending-draft cleanup is treated as complete.
    func saveApprovedDraftIdentitiesSync(_ identities: Set<String>) throws

    /// The user-facing activity history (item 21), newest first.
    func loadActivityEvents() -> [ActivityEvent]
    /// Persists the activity history (replaces the previous one).
    func saveActivityEvents(_ events: [ActivityEvent])

    /// The on-device approval-signal feedback store (item 83, Phase 1), newest
    /// first. Holds codes/numbers/hashes only (plus local deny "Other" free text).
    func loadDraftFeedback() -> [DraftFeedbackRecord]
    /// Persists the feedback store (replaces the previous one). Append-and-cap is
    /// the caller's responsibility, mirroring the activity history.
    func saveDraftFeedback(_ records: [DraftFeedbackRecord])
}

/// File-based persistence for non-secret application settings.
///
/// Data is stored as JSON in `~/Library/Application Support/Sentwise/`.
/// Writes are atomic and happen off the main thread.
final class PersistenceService: PersistenceProvider {

    // MARK: - Singleton

    static let shared = PersistenceService()

    // MARK: - Properties

    private let settingsURL: URL
    private let voiceProfileURL: URL
    private let processedMessagesURL: URL
    private let pendingDraftsURL: URL
    private let skippedMessagesURL: URL
    private let approvedDraftsURL: URL
    private let activityEventsURL: URL
    private let draftFeedbackURL: URL
    private let ioQueue = DispatchQueue(label: "com.tookes.Sentwise.persistence", qos: .utility)

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Initialization

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let directory = appSupport.appendingPathComponent("Sentwise", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("Settings.json")
        voiceProfileURL = directory.appendingPathComponent("VoiceProfile.json")
        processedMessagesURL = directory.appendingPathComponent("ProcessedMessages.json")
        pendingDraftsURL = directory.appendingPathComponent("PendingDrafts.json")
        skippedMessagesURL = directory.appendingPathComponent("SkippedMessages.json")
        approvedDraftsURL = directory.appendingPathComponent("ApprovedDrafts.json")
        activityEventsURL = directory.appendingPathComponent("ActivityEvents.json")
        draftFeedbackURL = directory.appendingPathComponent("DraftFeedback.json")
    }

    // MARK: - Settings

    func loadSettings() -> Settings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            logger.debug("No settings file, using defaults")
            return .default
        }
        do {
            let data = try Data(contentsOf: settingsURL)
            let settings = try decoder.decode(Settings.self, from: data)
            return settings.validated()
        } catch {
            logger.error("Failed to load settings: \(error.localizedDescription)")
            return .default
        }
    }

    func saveSettings(_ settings: Settings) {
        let validated = settings.validated()
        ioQueue.async { [encoder, settingsURL] in
            do {
                let data = try encoder.encode(validated)
                try data.write(to: settingsURL, options: .atomic)
            } catch {
                logger.error("Failed to save settings: \(error.localizedDescription)")
            }
        }
    }

    func saveSettingsSync(_ settings: Settings) throws {
        let validated = settings.validated()
        do {
            try ioQueue.sync { [encoder, settingsURL] in
                let data = try encoder.encode(validated)
                try data.write(to: settingsURL, options: .atomic)
            }
        } catch {
            logger.error("Failed to save settings (sync): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Voice Profile

    func loadVoiceProfile() -> VoiceProfile? {
        guard FileManager.default.fileExists(atPath: voiceProfileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: voiceProfileURL)
            return try decoder.decode(VoiceProfile.self, from: data)
        } catch {
            logger.error("Failed to load voice profile: \(error.localizedDescription)")
            return nil
        }
    }

    func saveVoiceProfile(_ profile: VoiceProfile) {
        ioQueue.async { [encoder, voiceProfileURL] in
            do {
                let data = try encoder.encode(profile)
                try data.write(to: voiceProfileURL, options: .atomic)
            } catch {
                logger.error("Failed to save voice profile: \(error.localizedDescription)")
            }
        }
    }

    func removeVoiceProfile() {
        ioQueue.async { [voiceProfileURL] in
            try? FileManager.default.removeItem(at: voiceProfileURL)
        }
    }

    // MARK: - Processed Messages

    func loadProcessedMessages() -> ProcessedMessages {
        guard FileManager.default.fileExists(atPath: processedMessagesURL.path) else {
            return ProcessedMessages()
        }
        do {
            let data = try Data(contentsOf: processedMessagesURL)
            return try decoder.decode(ProcessedMessages.self, from: data)
        } catch {
            logger.error("Failed to load processed messages: \(error.localizedDescription)")
            return ProcessedMessages()
        }
    }

    func saveProcessedMessages(_ processed: ProcessedMessages) {
        ioQueue.async { [encoder, processedMessagesURL] in
            do {
                let data = try encoder.encode(processed)
                try data.write(to: processedMessagesURL, options: .atomic)
            } catch {
                logger.error("Failed to save processed messages: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Pending Drafts

    func loadPendingDrafts() -> [Draft] {
        guard FileManager.default.fileExists(atPath: pendingDraftsURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: pendingDraftsURL)
            return try decoder.decode([Draft].self, from: data)
        } catch {
            logger.error("Failed to load pending drafts: \(error.localizedDescription)")
            return []
        }
    }

    func savePendingDraftsSync(_ drafts: [Draft]) throws {
        do {
            try ioQueue.sync { [encoder, pendingDraftsURL] in
                let data = try encoder.encode(drafts)
                try data.write(to: pendingDraftsURL, options: .atomic)
            }
        } catch {
            logger.error("Failed to save pending drafts: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Skipped Messages

    func loadSkippedMessages() -> [SkippedMessage] {
        guard FileManager.default.fileExists(atPath: skippedMessagesURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: skippedMessagesURL)
            return try decoder.decode([SkippedMessage].self, from: data)
        } catch {
            logger.error("Failed to load skipped messages: \(error.localizedDescription)")
            return []
        }
    }

    func saveSkippedMessagesSync(_ messages: [SkippedMessage]) throws {
        do {
            try ioQueue.sync { [encoder, skippedMessagesURL] in
                let data = try encoder.encode(messages)
                try data.write(to: skippedMessagesURL, options: .atomic)
            }
        } catch {
            logger.error("Failed to save skipped messages: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Approved Drafts

    func loadApprovedDraftIdentities() -> Set<String> {
        guard FileManager.default.fileExists(atPath: approvedDraftsURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: approvedDraftsURL)
            return Set(try decoder.decode([String].self, from: data))
        } catch {
            logger.error("Failed to load approved drafts: \(error.localizedDescription)")
            return []
        }
    }

    func saveApprovedDraftIdentitiesSync(_ identities: Set<String>) throws {
        do {
            try ioQueue.sync { [encoder, approvedDraftsURL] in
                let data = try encoder.encode(identities.sorted())
                try data.write(to: approvedDraftsURL, options: .atomic)
            }
        } catch {
            logger.error("Failed to save approved drafts: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Activity History

    func loadActivityEvents() -> [ActivityEvent] {
        guard FileManager.default.fileExists(atPath: activityEventsURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: activityEventsURL)
            return try decoder.decode([ActivityEvent].self, from: data)
        } catch {
            logger.error("Failed to load activity events: \(error.localizedDescription)")
            return []
        }
    }

    func saveActivityEvents(_ events: [ActivityEvent]) {
        ioQueue.async { [encoder, activityEventsURL] in
            do {
                let data = try encoder.encode(events)
                try data.write(to: activityEventsURL, options: .atomic)
            } catch {
                logger.error("Failed to save activity events: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Draft Feedback (item 83)

    func loadDraftFeedback() -> [DraftFeedbackRecord] {
        guard FileManager.default.fileExists(atPath: draftFeedbackURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: draftFeedbackURL)
            return try decoder.decode([DraftFeedbackRecord].self, from: data)
        } catch {
            logger.error("Failed to load draft feedback: \(error.localizedDescription)")
            return []
        }
    }

    func saveDraftFeedback(_ records: [DraftFeedbackRecord]) {
        ioQueue.async { [encoder, draftFeedbackURL] in
            do {
                let data = try encoder.encode(records)
                try data.write(to: draftFeedbackURL, options: .atomic)
            } catch {
                logger.error("Failed to save draft feedback: \(error.localizedDescription)")
            }
        }
    }
}
