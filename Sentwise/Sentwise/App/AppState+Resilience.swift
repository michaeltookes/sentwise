import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "Resilience")

/// Offline queue, reachability handling, and the shared retry wrappers for
/// item 27. The queue deliberately *reuses* the pending-draft store: an approved
/// draft that can't dispatch while offline simply stays pending (as it already
/// does until a send succeeds, per item 23) with a "waiting for network" flag,
/// and re-dispatches on reconnect through the normal approval path — so the
/// no-duplicate-send guards (`approvingDraftIDs`, the approved tombstone) all
/// still apply, and restart survival comes for free from the persisted queue.
extension AppState {

    // MARK: - Reachability lifecycle

    /// Begins reachability monitoring. Called by the app at launch (not in
    /// `init`) so tests never spin up a real `NWPathMonitor`.
    func startReachabilityMonitoring() {
        reachability.start()
        guard reachability.hasCurrentPath else { return }
        hasConfirmedReachability = true
        isOnline = reachability.isOnline
        guard isOnline else { return }
        Task { await resumeQueuedDraftsAfterReconnect() }
    }

    /// Stops reachability monitoring (app teardown).
    func stopReachabilityMonitoring() {
        reachability.stop()
    }

    /// Reacts to a reachability change: while offline the poll loop skips (see
    /// `pollInboxOnce`); on reconnect it polls immediately and drains any drafts
    /// that were queued while offline.
    func handleReachabilityChange(_ online: Bool) {
        let wasOnline = isOnline
        let hadConfirmedReachability = hasConfirmedReachability
        guard online != wasOnline || !hadConfirmedReachability else { return }
        hasConfirmedReachability = true
        isOnline = online
        guard online else {
            logger.info("Network offline — pausing polls and queueing dispatches")
            return
        }
        if hadConfirmedReachability, !wasOnline {
            logger.info("Network online — resuming polls and draining offline queue")
            recordActivity(ActivityEvent(kind: .resumedOnline, account: normalizedConnectedAccountEmail))
        } else {
            logger.info("Network online — draining restored offline queue")
        }
        guard llmProviderKind == .managed, isManagedSignedIn else {
            if watchStatus == .watching {
                resumeInboxWatcherAfterReachabilityConfirmed()
            }
            Task { await resumeQueuedDraftsAfterReconnect() }
            return
        }

        managedAccountStatusIsFresh = false
        Task {
            await refreshManagedQuota()
            if watchStatus == .watching {
                resumeInboxWatcherAfterReachabilityConfirmed()
            }
            await resumeQueuedDraftsAfterReconnect()
        }
    }

    // MARK: - Offline queue (reuses the pending-draft store)

    /// Whether a pending draft is deferred waiting for the network to return.
    func isWaitingForNetwork(_ identity: String) -> Bool {
        draftsWaitingForNetwork.contains(identity)
    }

    static func offlineQueuedDispatches(from drafts: [Draft]) -> [String: OfflineQueuedDraftDispatch] {
        var dispatches: [String: OfflineQueuedDraftDispatch] = [:]
        for draft in drafts {
            guard let intent = draft.offlineQueuedDispatch else { continue }
            guard !intent.isDispatchInFlight else { continue }
            dispatches[draft.identity] = intent
        }
        return dispatches
    }

    /// Defers an approved draft because we're offline: it stays pending, gains a
    /// "waiting for network" flag, and will dispatch on reconnect with the same
    /// send behavior. No send is attempted, so there's no risk of a partial send.
    func queueDraftForNetwork(
        _ draft: Draft,
        sendBehavior behavior: SendBehavior,
        force: Bool = false
    ) throws {
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else { return }
        let intent = OfflineQueuedDraftDispatch(sendBehavior: behavior, force: force)
        let previous = pendingDrafts[index]
        pendingDrafts[index].offlineQueuedDispatch = intent
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts[index] = previous
            logger.error("Failed to persist offline dispatch intent: \(error.localizedDescription)")
            throw error
        }
        offlineQueuedDispatch[draft.identity] = intent
        draftsWaitingForNetwork.insert(draft.identity)
        recordDraftActivity(.queuedOffline, for: pendingDrafts[index])
        logger.info("Queued draft for network (\(behavior.rawValue, privacy: .public), force: \(force, privacy: .public))")
    }

    /// Clears a single draft's offline-queue state (on deny, dispatch, or drain).
    @discardableResult
    func clearOfflineQueueEntry(_ identity: String) -> Bool {
        do {
            return try clearOfflineQueueEntryDurably(identity)
        } catch {
            logger.error("Failed to clear offline dispatch intent: \(error.localizedDescription)")
            return false
        }
    }

    func cancelQueuedDraftDispatch(_ identity: String) {
        approvalError = nil
        do {
            _ = try clearOfflineQueueEntryDurably(identity)
        } catch {
            approvalError = Self.draftMessage(for: error)
            logger.error("Failed to cancel offline dispatch intent: \(error.localizedDescription)")
        }
    }

    func clearOfflineQueueEntryDurably(_ identity: String) throws -> Bool {
        var nextDrafts = pendingDrafts
        let index = nextDrafts.firstIndex(where: { $0.identity == identity })
        let hadPersistedIntent = index.map { nextDrafts[$0].offlineQueuedDispatch != nil } ?? false

        if let index, hadPersistedIntent {
            nextDrafts[index].offlineQueuedDispatch = nil
            try persistence.savePendingDraftsSync(nextDrafts)
            pendingDrafts = nextDrafts
            pendingDraftCount = nextDrafts.count
        }

        let hadMemoryIntent = offlineQueuedDispatch.removeValue(forKey: identity) != nil
        let hadWaitingState = draftsWaitingForNetwork.remove(identity) != nil
        return hadPersistedIntent || hadMemoryIntent || hadWaitingState
    }

    func markOfflineQueueEntryDispatchInFlight(_ identity: String) throws {
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == identity }),
              var intent = pendingDrafts[index].offlineQueuedDispatch,
              !intent.isDispatchInFlight
        else { return }

        intent.isDispatchInFlight = true
        var nextDrafts = pendingDrafts
        nextDrafts[index].offlineQueuedDispatch = intent
        try persistence.savePendingDraftsSync(nextDrafts)
        pendingDrafts = nextDrafts
        pendingDraftCount = nextDrafts.count
        offlineQueuedDispatch.removeValue(forKey: identity)
        draftsWaitingForNetwork.remove(identity)
    }

    /// Clears every offline-queue entry (account switch, disconnect). The drafts
    /// themselves remain pending; they simply won't auto-dispatch.
    func clearAllOfflineQueueEntries() {
        do {
            _ = try clearAllOfflineQueueEntriesDurably()
        } catch {
            logger.error("Failed to clear offline dispatch intents: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func clearAllOfflineQueueEntriesDurably() throws -> Bool {
        let hasPersistedIntent = pendingDrafts.contains { $0.offlineQueuedDispatch != nil }
        guard hasPersistedIntent || !offlineQueuedDispatch.isEmpty || !draftsWaitingForNetwork.isEmpty else {
            return false
        }
        var nextDrafts = pendingDrafts
        var didClearPersistedIntent = false
        for index in nextDrafts.indices where nextDrafts[index].offlineQueuedDispatch != nil {
            nextDrafts[index].offlineQueuedDispatch = nil
            didClearPersistedIntent = true
        }
        if didClearPersistedIntent {
            try persistence.savePendingDraftsSync(nextDrafts)
            pendingDrafts = nextDrafts
            pendingDraftCount = nextDrafts.count
        }
        offlineQueuedDispatch.removeAll()
        draftsWaitingForNetwork.removeAll()
        return true
    }

    /// Re-dispatches every offline-queued draft through the normal approval path
    /// on reconnect. Waiting intents stay durable through countdowns and stale
    /// checks; once a network dispatch starts, the persisted marker becomes
    /// terminal so relaunch cannot repeat a send after post-send persistence fails.
    func resumeQueuedDraftsAfterReconnect() async {
        guard !isResumingQueuedDrafts else {
            needsQueuedDraftDrainAfterCurrent = true
            return
        }
        guard !offlineQueuedDispatch.isEmpty else { return }
        isResumingQueuedDrafts = true
        defer {
            needsQueuedDraftDrainAfterCurrent = false
            isResumingQueuedDrafts = false
        }

        repeat {
            needsQueuedDraftDrainAfterCurrent = false
            // Snapshot: approveDraft may re-queue entries, mutating the map mid-drain.
            let queued = offlineQueuedDispatch
            for (identity, intent) in queued {
                guard offlineQueuedDispatch[identity] == intent else { continue }
                guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else {
                    clearOfflineQueueEntry(identity)
                    continue
                }
                await approveDraft(draft, sendBehavior: intent.sendBehavior, force: intent.force)
                clearQueuedDispatchIfManualReviewNeeded(identity)
            }
        } while isOnline && needsQueuedDraftDrainAfterCurrent && !offlineQueuedDispatch.isEmpty
    }

    private func clearQueuedDispatchIfManualReviewNeeded(_ identity: String) {
        guard offlineQueuedDispatch[identity] != nil else { return }
        guard !approvingDraftIDs.contains(identity) else { return }
        guard pendingDrafts.contains(where: { $0.identity == identity }) else {
            clearOfflineQueueEntry(identity)
            return
        }
        guard pendingSendCountdowns[identity] == nil else { return }
        guard pendingStaleWarnings[identity] != nil || isOnline else { return }
        clearOfflineQueueEntry(identity)
    }

    func shouldQueueDispatchAfterOfflineFailure(
        _ error: Error,
        sendBehavior: SendBehavior
    ) -> Bool {
        guard !isOnline, ResilienceClassifier.classify(error) == .transient else { return false }
        // Without IMAP APPEND phase metadata, a connection failure after a save
        // attempt may already have created the draft. Leave it for manual review.
        guard sendBehavior != .saveAsDraft else { return false }
        return true
    }

    @discardableResult
    func dispatchApprovedDraftOrQueueOnOfflineFailure(
        _ draft: Draft,
        sendBehavior effectiveSendBehavior: SendBehavior,
        force: Bool,
        credentials: MailAccountCredentials
    ) async throws -> Bool {
        do {
            return try await dispatchApprovedDraft(
                draft,
                sendBehavior: effectiveSendBehavior,
                force: force,
                credentials: credentials
            )
        } catch {
            guard shouldQueueDispatchAfterOfflineFailure(
                error,
                sendBehavior: effectiveSendBehavior
            ) else { throw error }
            try queueDraftForNetwork(draft, sendBehavior: effectiveSendBehavior, force: force)
            return true
        }
    }

    // MARK: - Retry wrappers

    /// Runs a mail/LLM operation under the shared backoff policy, retrying only
    /// on transient failures. `sendInterruptedAfterSubmission`, auth failures, and
    /// permanent errors are never retried, so this can never cause a duplicate
    /// send: the SMTP layer only reports a pre-DATA drop as retryable.
    func withResilientRetry<T>(_ operation: () async throws -> T) async throws -> T {
        try await retryRunner.run(
            classify: ResilienceClassifier.retryDecision(for:),
            operation: operation
        )
    }

    /// Records exactly one failure activity for a dispatch error, its kind
    /// reflecting the cause: an auth failure (never retried) surfaces as
    /// `.authFailed`; a transient failure that survived every retry surfaces as
    /// `.retryExhausted`; a permanent or ambiguous-send failure surfaces as the
    /// caller's `failureKind` (`.sendFailed`/`.saveFailed`), whose detail carries
    /// the "may have been sent" note for the ambiguous case. Returns the
    /// classification so callers can react (e.g. pause watching).
    @discardableResult
    func recordDispatchFailureActivity(
        _ error: Error,
        for draft: Draft,
        failureKind: ActivityEventKind
    ) -> FailureClass {
        let classification = ResilienceClassifier.classify(error)
        let kind: ActivityEventKind
        switch classification {
        case .authentication:
            kind = .authFailed
        case .transient:
            kind = .retryExhausted
        case .ambiguousSend, .permanent:
            kind = failureKind
        }
        recordDraftActivity(kind, for: draft, detail: Self.draftMessage(for: error))
        return classification
    }

    /// The connected account email for activity linkage, or `nil` when none.
    var normalizedConnectedAccountEmail: String? {
        let email = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
    }
}
