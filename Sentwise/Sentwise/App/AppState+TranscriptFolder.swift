import Foundation
import os

private let transcriptFolderLogger = Logger(subsystem: "com.tookes.Sentwise", category: "TranscriptFolder")

/// Watched-folder lifecycle for the post-call follow-up workflow (item 51). Kept
/// in its own file so `AppState` stays within length limits.
extension AppState {

    /// The configured watched folder as a URL, or `nil` when unset.
    var transcriptWatchedFolderURL: URL? {
        let trimmed = transcriptWatchedFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// Starts the watcher if the feature is enabled and a folder is configured.
    /// Called at launch and after settings/connection changes. When a watcher for
    /// the same folder is already running it triggers a catch-up scan, so a
    /// transcript that arrived while the app couldn't yet draft is picked up once
    /// the app becomes ready. Idempotent.
    func startTranscriptFolderWatchingIfEnabled() {
        guard transcriptWatchedFolderEnabled, let url = transcriptWatchedFolderURL else {
            DiagnosticLog.verbose(
                "Transcript folder watcher inactive; enabled=\(self.transcriptWatchedFolderEnabled), "
                + "hasFolder=\(self.transcriptWatchedFolderURL != nil)"
            )
            stopTranscriptFolderWatching()
            return
        }
        // Rebuild if the target folder changed or a prior source failed to start;
        // otherwise catch up the running one.
        if let existing = transcriptFolderSource, existing.folderURL == url {
            guard existing.isActive else {
                stopTranscriptFolderWatching()
                return startTranscriptFolderWatchingIfEnabled()
            }
            existing.releaseDeferredDeliveries()
            DiagnosticLog.verbose("Transcript folder watcher already active; triggering catch-up scan")
            Task { @MainActor in
                await existing.scanForNewTranscripts()
            }
            return
        }
        stopTranscriptFolderWatching()

        transcriptFolderError = nil
        let source = WatchedFolderTranscriptSource(folderURL: url)
        source.loadSeenVersions = { [weak self] in
            self?.transcriptWatchedFolderSeenSnapshots
        }
        source.onSeenVersionsChanged = { [weak self, weak source] snapshots in
            guard let self, let source, self.transcriptFolderSource === source else { return false }
            return self.persistTranscriptWatchedFolderSeenSnapshots(snapshots)
        }
        source.onTranscriptValidatedDelivery = { [weak self] ingested, shouldCommit in
            await self?.handleWatchedTranscriptDelivery(
                ingested,
                shouldCommit: shouldCommit
            ) ?? .deferred
        }
        source.onError = { [weak self] error in
            self?.transcriptFolderError = Self.watchedFolderMessage(for: error)
        }
        transcriptFolderSource = source
        source.start()
        transcriptFolderLogger.info("Started watching transcript folder")
        DiagnosticLog.verbose("Transcript folder watcher started")
    }

    /// User-facing copy for a watched-folder failure.
    static func watchedFolderMessage(for error: WatchedFolderError) -> String {
        switch error {
        case .cannotOpenFolder(let path):
            return "Couldn't watch \(path). Check the folder exists and Sentwise has access to it."
        case .folderUnavailable(let path):
            return "The watched folder \(path) is no longer available. Choose it again in Settings."
        }
    }

    /// Stops and tears down the watcher. Idempotent.
    func stopTranscriptFolderWatching() {
        transcriptFolderSource?.stop()
        transcriptFolderSource = nil
    }

    /// Enables/disables the watched folder from the UI, persisting and (re)starting
    /// or stopping the watcher to match.
    func setTranscriptWatchedFolderEnabled(_ enabled: Bool) {
        guard enabled != transcriptWatchedFolderEnabled else { return }
        transcriptWatchedFolderEnabled = enabled
        transcriptWatchedFolderSeenSnapshots = nil
        saveSettings()
        startTranscriptFolderWatchingIfEnabled()
    }

    /// Points the watched folder at a new path from the UI, persisting and
    /// restarting the watcher to match.
    func setTranscriptWatchedFolderPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != transcriptWatchedFolderPath else { return }
        transcriptWatchedFolderPath = trimmed
        transcriptWatchedFolderSeenSnapshots = nil
        saveSettings()
        startTranscriptFolderWatchingIfEnabled()
    }

    /// Persists watched-folder version snapshots immediately so a transcript that
    /// is rejected for a retryable setup/provider issue stays eligible after an
    /// app restart instead of being re-seeded as pre-existing.
    @discardableResult
    func persistTranscriptWatchedFolderSeenSnapshots(_ snapshots: [String: WatchedFolderFileSnapshot]) -> Bool {
        let previous = transcriptWatchedFolderSeenSnapshots
        transcriptWatchedFolderSeenSnapshots = snapshots
        do {
            try persistSettingsSync(buildSettings())
            return true
        } catch {
            transcriptWatchedFolderSeenSnapshots = previous
            connectionError = Self.settingsMessage(action: "save", error: error)
            transcriptFolderLogger.error("Failed to save transcript folder snapshots: \(error.localizedDescription)")
            return false
        }
    }

    /// Handles a transcript that appeared in the watched folder: drafts a follow-up
    /// and enqueues it with no recipients yet (auto-fill is item 52), so the user
    /// adds recipients in review before approving. Returns whether the source should
    /// mark the transcript accepted. Setup and transient failures return `false`;
    /// permanent failures are treated as handled so the source does not repeat cloud
    /// generation indefinitely for an unchanged file.
    @discardableResult
    func handleWatchedTranscript(_ ingested: IngestedTranscript) async -> Bool {
        await handleWatchedTranscriptDelivery(ingested).isAccepted
    }

    func handleWatchedTranscriptDelivery(
        _ ingested: IngestedTranscript,
        shouldCommit: (() -> Bool)? = nil
    ) async -> WatchedTranscriptDeliveryResult {
        DiagnosticLog.verbose("Watched transcript delivery started")
        guard canCreateFollowUp else {
            transcriptFolderError =
                "A transcript arrived, but connect an email account and AI provider to draft follow-ups."
            DiagnosticLog.verbose("Watched transcript delivery deferred; mail or AI is unavailable")
            return .deferred
        }
        do {
            let draft = try await createFollowUp(from: ingested, shouldCommit: shouldCommit)
            transcriptFolderError = nil
            DiagnosticLog.verbose(
                "Watched transcript delivery accepted; pendingDraftCount=\(self.pendingDrafts.count)"
            )
            return .acceptedWithRollback { [weak self] in
                self?.rollbackWatchedFollowUp(draft)
            }
        } catch FollowUpCommitError.sourceChanged {
            DiagnosticLog.verbose("Watched transcript delivery retrying; source changed before commit")
            return .retry
        } catch {
            transcriptFolderError = Self.draftMessage(for: error)
            transcriptFolderLogger.error("Watched-folder follow-up failed: \(error.localizedDescription)")
            let result = Self.watchedTranscriptDeliveryResult(for: error)
            DiagnosticLog.verbose(
                "Watched transcript delivery failed; result=\(result.diagnosticLabel)"
            )
            return result
        }
    }

    private static func watchedTranscriptDeliveryResult(for error: Error) -> WatchedTranscriptDeliveryResult {
        switch error {
        case let error as FollowUpCommitError:
            switch error {
            case .sourceChanged, .pendingDraftPersistenceFailed:
                return .retry
            }
        case DraftError.llmUnavailable,
             DraftDispatchError.missingCredentials,
             DraftDispatchError.accountChanged:
            return .deferred
        default:
            switch ResilienceClassifier.classify(error) {
            case .transient:
                return .retry
            case .authentication:
                return .deferred
            case .ambiguousSend, .permanent:
                return .accepted
            }
        }
    }

    private func rollbackWatchedFollowUp(_ draft: Draft) {
        do {
            try rollbackPendingFollowUp(draft)
        } catch {
            transcriptFolderError = Self.draftMessage(for: error)
            transcriptFolderLogger.error(
                "Failed to roll back changed watched-folder follow-up: \(error.localizedDescription)"
            )
        }
    }
}
