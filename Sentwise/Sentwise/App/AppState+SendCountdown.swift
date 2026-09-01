import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "SendCountdown")

/// Auto-send safety net (item 23): a short, cancellable grace period between the
/// user approving an auto-send draft and the actual SMTP dispatch. The draft is
/// left in the pending queue for the whole window, so a quit or crash mid-window
/// leaves it pending — never lost, never sent. The stale-thread re-check (item 12)
/// runs at the END of the window, immediately before the send, so a thread that
/// moved on during the countdown is still caught. Kept in its own file so
/// `AppState+PendingDrafts` stays within lint limits.
extension AppState {

    /// The remaining seconds on an in-progress send countdown for `identity`, or
    /// `nil` when that draft is not counting down. Drives the review UI.
    func sendCountdownRemaining(for identity: String) -> Int? {
        pendingSendCountdowns[identity]
    }

    /// Runs the stale-thread re-check (unless forced) and then sends or saves the
    /// draft, finalizing it on success. Shared by the immediate-approval path and
    /// the end of the auto-send countdown, so both re-check freshness at dispatch
    /// time and record the same activity/tombstone bookkeeping.
    @discardableResult
    func dispatchApprovedDraft(
        _ draft: Draft,
        sendBehavior effectiveSendBehavior: SendBehavior,
        force: Bool,
        credentials: MailAccountCredentials
    ) async throws -> Bool {
        var dispatchCredentials = credentials
        if !force {
            let freshness = try await currentFreshnessCheck(for: draft, credentials: credentials)
            dispatchCredentials = freshness.credentials
            if let reason = freshness.reason {
                recordPendingStaleWarning(reason, for: draft)
                return false
            }
        }
        pendingStaleWarnings.removeValue(forKey: draft.identity)
        try markOfflineQueueEntryDispatchInFlight(draft.identity)

        switch effectiveSendBehavior {
        case .autoSend:
            try await performSend(draft, credentials: dispatchCredentials)
        case .saveAsDraft:
            try await performSave(draft, credentials: dispatchCredentials)
        }
        // Terminal approve (item 83): capture as-is/edited outcome + magnitude,
        // send behavior, provenance, and answered-needs-info now that dispatch
        // succeeded. This is the one choke point for both immediate approval and
        // the end of the auto-send countdown, and the offline drain re-enters here
        // on reconnect, so the signal is recorded exactly once at real dispatch.
        recordApprovalFeedback(for: draft, sendBehavior: effectiveSendBehavior)
        try finalizeApprovedDraft(draft)
        return true
    }

    /// Starts a cancellable per-draft countdown before an auto-send dispatch. The
    /// draft stays in the pending queue for the whole window (recoverable); only
    /// after the window elapses AND the send succeeds is it removed.
    func startSendCountdown(
        for draft: Draft,
        credentials: MailAccountCredentials,
        surfaceBlockedDispatch: Bool = false
    ) {
        let identity = draft.identity
        guard sendCountdownTasks[identity] == nil else { return }
        if surfaceBlockedDispatch {
            sendCountdownNotificationApprovalIDs.insert(identity)
        }
        let seconds = max(sendDelaySeconds, 1)
        pendingSendCountdowns[identity] = seconds
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSendCountdown(for: draft, credentials: credentials, seconds: seconds)
        }
        sendCountdownTasks[identity] = task
    }

    private func runSendCountdown(
        for draft: Draft,
        credentials: MailAccountCredentials,
        seconds: Int
    ) async {
        let identity = draft.identity
        var remaining = seconds
        while remaining > 0 {
            do {
                try await Task.sleep(nanoseconds: sendCountdownTickNanoseconds)
            } catch {
                return // Cancelled — the canceller owns state cleanup.
            }
            if Task.isCancelled { return }
            remaining -= 1
            // Only reflect the tick while this is still the active countdown.
            guard pendingSendCountdowns[identity] != nil else { return }
            pendingSendCountdowns[identity] = remaining
        }
        if Task.isCancelled { return }
        await fireSendCountdown(for: draft, credentials: credentials)
    }

    /// Fires at the end of the window: dispatches the (possibly edited) draft after
    /// re-checking staleness. On a stale verdict the send is blocked and the
    /// existing stale-warning flow surfaces instead; the draft stays pending.
    private func fireSendCountdown(for draft: Draft, credentials: MailAccountCredentials) async {
        let identity = draft.identity
        let shouldSurfaceBlockedDispatch = sendCountdownNotificationApprovalIDs.remove(identity) != nil
        pendingSendCountdowns.removeValue(forKey: identity)
        sendCountdownTasks.removeValue(forKey: identity)

        guard let current = currentDraftForCountdownDispatch(identity: identity) else { return }
        // Never double-dispatch if an approval is already in flight for it.
        guard !approvingDraftIDs.contains(identity) else { return }

        // Went offline during the window (item 27): defer the send rather than
        // attempt it. It re-dispatches on reconnect through the normal path.
        if !isOnline {
            do {
                try queueDraftForNetwork(current, sendBehavior: .autoSend)
            } catch {
                approvalError = Self.draftMessage(for: error)
                logger.error("Failed to queue auto-send after countdown: \(error.localizedDescription)")
            }
            return
        }

        approvingDraftIDs.insert(identity)
        defer { approvingDraftIDs.remove(identity) }
        do {
            // `current` carries any inline edit (item 19) made during the window.
            let didDispatch = try await dispatchApprovedDraftOrQueueOnOfflineFailure(
                current,
                sendBehavior: .autoSend,
                force: false,
                credentials: credentials
            )
            if !didDispatch {
                clearOfflineQueueEntry(identity)
                surfaceBlockedSendCountdown(for: current, notifyUser: shouldSurfaceBlockedDispatch)
            }
        } catch {
            if offlineQueuedDispatch[identity] != nil, isOnline {
                clearOfflineQueueEntry(identity)
            }
            approvalError = Self.draftMessage(for: error)
            logger.error("Auto-send after countdown failed: \(error.localizedDescription)")
        }
    }

    private func currentDraftForCountdownDispatch(identity: String) -> Draft? {
        // The draft may have been denied/removed during the window.
        guard var current = pendingDrafts.first(where: { $0.identity == identity }) else { return nil }
        if let editedBody = pendingDraftUncommittedEditBodies[identity] {
            guard let updated = updatePendingDraftBody(current, to: editedBody) else {
                openReviewHandler?()
                return nil
            }
            current = updated
        }
        if let recipients = pendingDraftUncommittedEditRecipients[identity] {
            guard let updated = updatePendingDraftRecipients(current, to: recipients) else {
                openReviewHandler?()
                return nil
            }
            current = updated
        }
        guard !pendingDraftUncommittedEditIDs.contains(identity) else {
            approvalError = "Review this draft before sending; it has unsaved edits."
            openReviewHandler?()
            return nil
        }
        guard !current.isAuthored || current.hasAuthoredRecipients else {
            approvalError = Self.draftMessage(for: DraftDispatchError.noRecipient)
            openReviewHandler?()
            return nil
        }
        guard !current.isFlagged else {
            approvalError = Self.draftMessage(for: DraftError.needsUserInput)
            openReviewHandler?()
            return nil
        }
        return current
    }

    private func surfaceBlockedSendCountdown(for draft: Draft, notifyUser: Bool) {
        guard notifyUser else { return }
        notifier.notify(for: draft, sendBehavior: .autoSend)
        openReviewHandler?()
    }

    /// User-initiated cancel during the window (item 23): stops the countdown and
    /// leaves the draft in the pending queue untouched, with any inline edits
    /// (item 19) preserved. If the countdown came from a reconnect drain, its
    /// durable offline dispatch intent is cleared too. Records `.sendCanceled`.
    func cancelSendCountdown(_ draft: Draft) {
        let identity = draft.identity
        guard let task = sendCountdownTasks.removeValue(forKey: identity) else { return }
        task.cancel()
        sendCountdownNotificationApprovalIDs.remove(identity)
        pendingSendCountdowns.removeValue(forKey: identity)
        approvalError = nil
        do {
            if offlineQueuedDispatch[identity] != nil || isWaitingForNetwork(identity) {
                _ = try clearOfflineQueueEntryDurably(identity)
            }
        } catch {
            approvalError = Self.draftMessage(for: error)
            logger.error(
                "Failed to clear queued dispatch after canceling send countdown: \(error.localizedDescription)"
            )
            return
        }
        recordDraftActivity(.sendCanceled, for: draft)
    }

    /// Cancels every outstanding countdown without recording an activity entry.
    /// Used when the account switches, watching stops, or the app terminates — the
    /// pending drafts remain queued and simply never auto-fire.
    func cancelAllSendCountdowns() {
        guard !sendCountdownTasks.isEmpty else { return }
        for task in sendCountdownTasks.values {
            task.cancel()
        }
        sendCountdownTasks.removeAll()
        sendCountdownNotificationApprovalIDs.removeAll()
        pendingSendCountdowns.removeAll()
    }
}
