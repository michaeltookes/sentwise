import Foundation
import os

private let watchedFolderLogger = Logger(subsystem: DiagnosticLog.subsystem, category: "TranscriptFolder")

/// Watches a folder for new transcript files and delivers each newly appeared one
/// to `onTranscript` (item 51) — e.g. Zoom's local recording directory. This is
/// the v1 `TranscriptSource`; platform integrations (item 53) and native capture
/// (item 54) will conform the same way.
///
/// Event-driven via a `DispatchSourceFileSystemObject` on the root folder plus a
/// bounded recursive rescan loop, mirroring how `InboxWatcher` splits mechanism
/// from policy: the new-vs-seen bookkeeping is the pure `WatchedFolderScanner`,
/// and delivery is `onTranscript`, so a scan can be driven deterministically in
/// tests without real FS events. A file is marked processed only after it is
/// ingested *and* accepted by the delivery callback, so a file that appears
/// mid-write or arrives before the app can draft is retried on a later scan
/// rather than being permanently dropped. It never moves or deletes the user's
/// files.
@MainActor
final class WatchedFolderTranscriptSource: TranscriptSource {

    let kind: TranscriptSourceKind = .watchedFolder
    var onTranscript: ((IngestedTranscript) async -> Bool)?
    var onTranscriptDelivery: ((IngestedTranscript) async -> WatchedTranscriptDeliveryResult)?
    var onTranscriptValidatedDelivery: WatchedTranscriptValidatedDelivery?

    /// Reports a watch-start or watch-loss failure so the owner can surface it.
    var onError: ((WatchedFolderError) -> Void)?

    /// Loads the persisted seen-version baseline for this folder, if one has
    /// already been established.
    var loadSeenVersions: (() -> [String: WatchedFolderFileSnapshot]?)?

    /// Persists accepted/seeded seen-version snapshots for restart-safe retries.
    /// Returns `true` only when the snapshot map was durably saved.
    var onSeenVersionsChanged: (([String: WatchedFolderFileSnapshot]) -> Bool)?

    let folderURL: URL
    private let fileManager: FileManager
    private var source: DispatchSourceFileSystemObject?
    private var startupSeedTask: Task<Void, Never>?
    private var startupCatchUpTask: Task<Void, Never>?
    private var recursiveRescanTask: Task<Void, Never>?
    var rejectedDeliveryRetryTask: Task<Void, Never>?
    private var fileStabilityRetryTask: Task<Void, Never>?
    private var seenPersistenceRetryTask: Task<Void, Never>?
    var pendingFileStability: [String: PendingFileStability] = [:]
    var rejectedDeliveries: [String: WatchedFolderRejectedDeliveryState] = [:]
    private var seen: [String: WatchedFolderFileSnapshot] = [:]
    private var seenPersistencePending = false
    private var processing: Set<String> = []
    private var isScanning = false
    private var needsScanAfterCurrent = false
    var isRunning = false
    var recursiveRescanDelayNanoseconds: UInt64 = 30_000_000_000
    var rejectedDeliveryRetryDelayNanoseconds: UInt64 = 30_000_000_000
    var rejectedDeliveryMaxRetryDelayNanoseconds: UInt64 = 300_000_000_000
    var rejectedDeliveryMaxAttempts = 4
    var fileStabilityDelayNanoseconds: UInt64 = 2_000_000_000
    var seenPersistenceRetryDelayNanoseconds: UInt64 = 30_000_000_000
    private let startupCatchUpDelayNanoseconds: UInt64 = 50_000_000

    #if DEBUG
    var onAfterSeedSeenForTesting: (() -> Void)?
    var onAfterScanDiscoveryForTesting: (() -> Void)?
    var onBeforeIngestForTesting: ((URL) -> Void)?
    #endif

    /// Whether the folder is currently being watched. Reflects reality — it is
    /// only true after the descriptor opened successfully.
    var isActive: Bool { isRunning }

    init(folderURL: URL, fileManager: FileManager = .default) {
        self.folderURL = folderURL
        self.fileManager = fileManager
    }

    /// Begins watching. Files already present when watching starts are seeded as
    /// seen, so only files that appear afterwards trigger the workflow. If the
    /// folder can't be opened, reports the failure and stays inactive. Idempotent.
    func start() {
        guard !isRunning else { return }
        let startupBoundary = Date()
        guard openWatch() else {
            report(.cannotOpenFolder(folderURL.path))
            return
        }
        isRunning = true
        startupSeedTask = Task { @MainActor [weak self] in
            await self?.finishStartupSeed(startedAt: startupBoundary)
        }
    }

    /// Stops watching and releases the folder descriptor. Idempotent.
    func stop() {
        isRunning = false
        isScanning = false
        needsScanAfterCurrent = false
        cancelScheduledWork()
        teardownWatch()
    }

    /// Rescans the folder and delivers any newly appeared transcript files. A file
    /// is marked processed only once it ingests and the delivery callback accepts
    /// it. Internal so the FS-event handler and tests can trigger a scan.
    func scanForNewTranscripts() async {
        if let startupSeedTask {
            await startupSeedTask.value
        }
        guard isRunning else { return }
        cancelStartupCatchUpScanIfPending()
        if isScanning {
            needsScanAfterCurrent = true
            return
        }

        isScanning = true
        repeat {
            needsScanAfterCurrent = false
            await scanForNewTranscriptsOnce()
        } while isRunning && needsScanAfterCurrent
        isScanning = false
    }

    private func scanForNewTranscriptsOnce() async {
        guard isRunning else { return }
        let discovery = await currentContents()
        #if DEBUG
        onAfterScanDiscoveryForTesting?()
        #endif
        guard isRunning, !Task.isCancelled else { return }
        retryPendingSeenPersistence()
        let reconciledSeen = WatchedFolderScanner.reconcileSeenVersions(
            seen,
            with: discovery.urls,
            pruneMissing: discovery.isComplete
        )
        updateSeenVersions(reconciledSeen)
        let candidates = WatchedFolderScanner.newTranscripts(in: discovery.urls, alreadySeen: seen)
        let candidateKeys = Set(candidates.map(WatchedFolderScanner.seenKey(for:)))
        pendingFileStability = pendingFileStability.filter { candidateKeys.contains($0.key) }
        rejectedDeliveries = rejectedDeliveries.filter { candidateKeys.contains($0.key) }
        for url in candidates where isRunning {
            await processCandidate(url)
        }
    }
}
extension WatchedFolderTranscriptSource {
    // MARK: - Mechanism

    private func finishStartupSeed(startedAt startupBoundary: Date) async {
        while isRunning && !Task.isCancelled {
            let discovery = await currentContents()
            guard isRunning, !Task.isCancelled else { return }
            let persisted = loadSeenVersions?()
            if persisted == nil
                && !WatchedFolderStartupSeed.canEstablishInitialBaseline(discoveryIsComplete: discovery.isComplete) {
                try? await Task.sleep(nanoseconds: recursiveRescanDelayNanoseconds)
                continue
            }
            let didPersistSeed = updateSeenVersions(
                startupSeenVersions(from: discovery, startedAt: startupBoundary, persisted: persisted),
                forcePersist: persisted == nil
            )
            if persisted == nil, !didPersistSeed {
                try? await Task.sleep(nanoseconds: recursiveRescanDelayNanoseconds)
                continue
            }
            startupSeedTask = nil
            #if DEBUG
            onAfterSeedSeenForTesting?()
            #endif
            startRecursiveRescanLoop()
            scheduleStartupCatchUpScan()
            return
        }
    }

    private func startupSeenVersions(
        from discovery: WatchedFolderDiscoveryResult,
        startedAt startupBoundary: Date,
        persisted: [String: WatchedFolderFileSnapshot]?
    ) -> [String: WatchedFolderFileSnapshot] {
        guard let persisted else {
            let baselineContents = discovery.urls.filter {
                WatchedFolderStartupSeed.existedBeforeStartup($0, startedAt: startupBoundary)
            }
            return WatchedFolderScanner.seedSeenVersions(from: baselineContents)
        }
        return WatchedFolderScanner.reconcileSeenVersions(
            persisted,
            with: discovery.urls,
            pruneMissing: discovery.isComplete
        )
    }

    func updateSeenVersion(_ snapshot: WatchedFolderFileSnapshot, forKey key: String) {
        var nextSeen = seen
        nextSeen[key] = snapshot
        updateSeenVersions(nextSeen)
    }

    @discardableResult
    private func updateSeenVersions(
        _ snapshots: [String: WatchedFolderFileSnapshot],
        forcePersist: Bool = false
    ) -> Bool {
        guard seen != snapshots || forcePersist else {
            retryPendingSeenPersistence()
            return !seenPersistencePending
        }
        seen = snapshots
        if persistSeenVersions(seen) {
            seenPersistencePending = false
            seenPersistenceRetryTask?.cancel()
            seenPersistenceRetryTask = nil
            return true
        } else {
            seenPersistencePending = true
            scheduleSeenPersistenceRetry()
            return false
        }
    }

    private func retryPendingSeenPersistence() {
        guard seenPersistencePending else { return }
        if persistSeenVersions(seen) {
            seenPersistencePending = false
            seenPersistenceRetryTask?.cancel()
            seenPersistenceRetryTask = nil
        } else {
            scheduleSeenPersistenceRetry()
        }
    }

    private func persistSeenVersions(_ snapshots: [String: WatchedFolderFileSnapshot]) -> Bool {
        onSeenVersionsChanged?(snapshots) ?? true
    }

    private func processCandidate(_ url: URL) async {
        let key = WatchedFolderScanner.seenKey(for: url)
        guard !processing.contains(key) else { return }
        guard isStableForDelivery(url, key: key) else { return }
        guard let deliveredSnapshot = pendingFileStability[key]?.snapshot else {
            scheduleFileStabilityRetry()
            return
        }
        guard shouldAttemptDelivery(forKey: key, snapshot: deliveredSnapshot) else { return }
        #if DEBUG
        onBeforeIngestForTesting?(url)
        #endif
        let ingested: IngestedTranscript
        do {
            ingested = try await ingestTranscript(at: url)
        } catch {
            guard WatchedFolderFileSnapshot(url: url) == deliveredSnapshot else {
                pendingFileStability.removeValue(forKey: key)
                scheduleFileStabilityRetry()
                return
            }
            handleStableIngestFailure(error, for: url, key: key, snapshot: deliveredSnapshot)
            return
        }
        guard isRunning else { return }
        guard WatchedFolderFileSnapshot(url: url) == deliveredSnapshot else {
            pendingFileStability.removeValue(forKey: key)
            scheduleFileStabilityRetry()
            return
        }
        let shouldCommitDelivery = { [weak self] in
            self?.isCurrentDeliverySnapshot(url, snapshot: deliveredSnapshot) == true
        }
        processing.insert(key)
        let result = await transcriptDeliveryResult(for: ingested, shouldCommit: shouldCommitDelivery)
        processing.remove(key)
        guard isRunning else { return }
        guard shouldCommitDelivery() else {
            await rollbackAcceptedDeliveryIfNeeded(result)
            pendingFileStability.removeValue(forKey: key)
            scheduleFileStabilityRetry()
            return
        }
        handleDeliveryResult(result, forKey: key, snapshot: deliveredSnapshot)
    }

    private func currentContents() async -> WatchedFolderDiscoveryResult {
        await WatchedFolderDiscovery.currentContents(folderURL: folderURL, fileManager: fileManager)
    }

    /// Opens the folder descriptor and starts the dispatch source. Returns whether
    /// the open succeeded. Each source's cancel handler closes its own captured
    /// descriptor, so a re-open can never race a stale cancel into a wrong close.
    private func openWatch() -> Bool {
        guard let watch = makeWatch(for: folderURL, isRoot: true) else { return false }
        source = watch
        return true
    }

    private func makeWatch(for url: URL, isRoot: Bool) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        watch.setEventHandler { [weak self] in
            let flags = watch.data
            Task { @MainActor in
                await self?.handleEvent(flags, isRoot: isRoot)
            }
        }
        watch.setCancelHandler { close(descriptor) }
        watch.resume()
        return watch
    }

    private func teardownWatch() {
        source?.cancel()
        source = nil
    }

    private func cancelScheduledWork() {
        startupSeedTask?.cancel()
        startupCatchUpTask?.cancel()
        recursiveRescanTask?.cancel()
        rejectedDeliveryRetryTask?.cancel()
        fileStabilityRetryTask?.cancel()
        seenPersistenceRetryTask?.cancel()
        startupSeedTask = nil
        startupCatchUpTask = nil
        recursiveRescanTask = nil
        rejectedDeliveryRetryTask = nil
        fileStabilityRetryTask = nil
        seenPersistenceRetryTask = nil
        pendingFileStability.removeAll()
        rejectedDeliveries.removeAll()
    }

    private func scheduleStartupCatchUpScan() {
        guard startupCatchUpTask == nil else { return }
        startupCatchUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.startupCatchUpDelayNanoseconds)
            } catch {
                self.startupCatchUpTask = nil
                return
            }
            guard !Task.isCancelled, self.isRunning else {
                self.startupCatchUpTask = nil
                return
            }
            self.startupCatchUpTask = nil
            await self.scanForNewTranscripts()
        }
    }

    private func cancelStartupCatchUpScanIfPending() {
        guard startupCatchUpTask != nil, !isScanning else { return }
        startupCatchUpTask?.cancel()
        startupCatchUpTask = nil
    }

    private func startRecursiveRescanLoop() {
        guard recursiveRescanTask == nil else { return }
        recursiveRescanTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.recursiveRescanDelayNanoseconds)
                if Task.isCancelled { return }
                await self.scanForNewTranscripts()
            }
        }
    }

    private func isStableForDelivery(_ url: URL, key: String) -> Bool {
        guard let snapshot = WatchedFolderFileSnapshot(url: url) else {
            pendingFileStability.removeValue(forKey: key)
            return false
        }

        let now = Date()
        if fileStabilityDelayNanoseconds == 0 {
            pendingFileStability[key] = PendingFileStability(snapshot: snapshot, observedAt: now)
            return true
        }

        if let pending = pendingFileStability[key], pending.snapshot == snapshot {
            if now.timeIntervalSince(pending.observedAt) >= fileStabilityDelaySeconds {
                return true
            }
            scheduleFileStabilityRetry()
            return false
        }

        pendingFileStability[key] = PendingFileStability(snapshot: snapshot, observedAt: now)
        scheduleFileStabilityRetry()
        return false
    }

    private func handleStableIngestFailure(
        _ error: Error,
        for url: URL,
        key: String,
        snapshot: WatchedFolderFileSnapshot
    ) {
        switch error {
        case TranscriptIngestError.emptyTranscript, TranscriptIngestError.unsupportedFormat(_):
            updateSeenVersion(snapshot, forKey: key)
        default:
            // Permission and decoding failures may recover without changing the
            // tracked file snapshot, so leave the file retryable on later scans.
            watchedFolderLogger.debug(
                "Transcript file not readable yet; will retry on a later scan: \(url.path)"
            )
        }
        pendingFileStability.removeValue(forKey: key)
    }

    private var fileStabilityDelaySeconds: TimeInterval {
        TimeInterval(fileStabilityDelayNanoseconds) / 1_000_000_000
    }

    private func scheduleFileStabilityRetry() {
        guard isRunning, fileStabilityDelayNanoseconds > 0, fileStabilityRetryTask == nil else { return }
        fileStabilityRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.fileStabilityDelayNanoseconds)
            } catch {
                self.fileStabilityRetryTask = nil
                return
            }
            guard self.isRunning else {
                self.fileStabilityRetryTask = nil
                return
            }
            self.fileStabilityRetryTask = nil
            await self.scanForNewTranscripts()
        }
    }

    private func scheduleSeenPersistenceRetry() {
        guard isRunning, seenPersistenceRetryTask == nil else { return }
        seenPersistenceRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.seenPersistenceRetryDelayNanoseconds)
            } catch {
                self.seenPersistenceRetryTask = nil
                return
            }
            guard self.isRunning else {
                self.seenPersistenceRetryTask = nil
                return
            }
            self.seenPersistenceRetryTask = nil
            self.retryPendingSeenPersistence()
        }
    }

    private func handleEvent(_ flags: DispatchSource.FileSystemEvent, isRoot: Bool) async {
        if isRoot, flags.contains(.delete) || flags.contains(.rename) {
            await handleFolderMoved()
        } else {
            guard startupSeedTask == nil, startupCatchUpTask == nil else { return }
            await scanForNewTranscripts()
        }
    }

    /// The watched folder itself was renamed or deleted, so the descriptor points
    /// at a stale inode. Re-open the path if something is still there; otherwise
    /// surface the loss so the UI stops claiming to watch.
    private func handleFolderMoved() async {
        teardownWatch()
        guard fileManager.fileExists(atPath: folderURL.path) else {
            isRunning = false
            cancelScheduledWork()
            report(.folderUnavailable(folderURL.path))
            return
        }
        guard openWatch() else {
            isRunning = false
            cancelScheduledWork()
            report(.cannotOpenFolder(folderURL.path))
            return
        }
        await scanForNewTranscripts()
    }

    private func report(_ error: WatchedFolderError) {
        watchedFolderLogger.error("Transcript folder watch failed: \(String(describing: error))")
        onError?(error)
    }
}
