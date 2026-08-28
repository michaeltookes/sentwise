import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "PendingDrafts")
private enum RegenerationReplacementError: LocalizedError {
    case alreadyApproved

    var errorDescription: String? {
        "That replacement draft was already approved. The original draft is still queued for review."
    }
}

private struct RegenerationSourceMessage {
    var message: MailMessage
    var mailbox: Mailbox
}

/// Approval-queue actions on `AppState`.
extension AppState {

    /// What "Approve" will do for the current send-behavior setting.
    var approveActionLabel: String {
        sendBehavior == .autoSend ? "Send" : "Save to Drafts"
    }

    /// Approves a pending draft and removes it from the queue on success.
    /// Unless `force` is set, the draft's thread is re-checked first; if it
    /// changed, the review card gets a stale warning instead of dispatching.
    /// Passing `force: true` is the user's "send anyway" override.
    func approveDraft(
        _ draft: Draft,
        sendBehavior approvalSendBehavior: SendBehavior? = nil,
        force: Bool = false,
        surfaceDelayedBlocks: Bool = false
    ) async {
        do {
            guard let credentials = try queuedApprovalCredentials(for: draft) else { return }
            approvingDraftIDs.insert(draft.identity)
            defer { approvingDraftIDs.remove(draft.identity) }

            try await approveQueuedDraft(
                draft,
                sendBehavior: approvalSendBehavior,
                force: force,
                surfaceDelayedBlocks: surfaceDelayedBlocks,
                credentials: credentials
            )
        } catch {
            approvalError = Self.draftMessage(for: error)
        }
    }

    private func queuedApprovalCredentials(for draft: Draft) throws -> MailAccountCredentials? {
        guard pendingDrafts.contains(where: { $0.identity == draft.identity }) else { return nil }
        guard !approvingDraftIDs.contains(draft.identity) else { return nil }
        // A draft already counting down toward an auto-send (item 23) must not be
        // re-approved into a second countdown or a double-send.
        guard pendingSendCountdowns[draft.identity] == nil else { return nil }

        approvalError = nil
        // A flagged draft needs the user's input first — never send or save it,
        // even via a notification "Approve" action in auto-send mode (item 13).
        guard !draft.isFlagged else {
            throw DraftError.needsUserInput
        }
        // An authored follow-up (item 51) can't dispatch until it has recipients;
        // the user supplies them in review before approving.
        guard !draft.isAuthored || draft.hasAuthoredRecipients else {
            throw DraftDispatchError.noRecipient
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            throw DraftDispatchError.missingCredentials
        }
        guard draftMatchesCurrentAccount(draft, credentials: credentials) else {
            throw DraftDispatchError.accountMismatch
        }
        guard draftSourceAllowsReplyDispatch(draft) else {
            throw DraftError.unsupportedSourceMailbox
        }
        return credentials
    }

    private func approveQueuedDraft(
        _ draft: Draft,
        sendBehavior approvalSendBehavior: SendBehavior?,
        force: Bool,
        surfaceDelayedBlocks: Bool,
        credentials: MailAccountCredentials
    ) async throws {
        let effectiveSendBehavior = approvalSendBehavior ?? sendBehavior
        // Offline (item 27): defer before starting any auto-send countdown, so
        // the approved intent is durable even if the app quits during the delay.
        if !isOnline {
            try queueDraftForNetwork(draft, sendBehavior: effectiveSendBehavior, force: force)
            return
        }
        // Auto-send safety net (item 23): unless disabled (delay 0), or the user
        // is forcing a stale "send anyway", an auto-send approval starts a
        // cancellable countdown instead of dispatching now. The draft stays in the
        // pending queue for the whole window — recoverable across a quit/crash —
        // and the stale-thread re-check (item 12) runs at the END of the window,
        // immediately before dispatch. Save-as-draft and instant mode dispatch now.
        if effectiveSendBehavior == .autoSend, !force, sendDelaySeconds > 0 {
            startSendCountdown(
                for: draft,
                credentials: credentials,
                surfaceBlockedDispatch: surfaceDelayedBlocks
            )
            return
        }
        do {
            let didDispatch = try await dispatchApprovedDraftOrQueueOnOfflineFailure(
                draft,
                sendBehavior: effectiveSendBehavior,
                force: force,
                credentials: credentials
            )
            if !didDispatch {
                clearOfflineQueueEntry(draft.identity)
            }
        } catch {
            if offlineQueuedDispatch[draft.identity] != nil, isOnline || effectiveSendBehavior == .saveAsDraft {
                clearOfflineQueueEntry(draft.identity)
            }
            throw error
        }
    }

    func currentFreshnessCheck(
        for draft: Draft,
        credentials: MailAccountCredentials
    ) async throws -> (reason: StaleThreadReason?, credentials: MailAccountCredentials) {
        let verdict = await threadStalenessVerdict(for: draft, credentials: credentials)
        let currentCredentials = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
        return (verdict.reason, currentCredentials)
    }

    func recordPendingStaleWarning(_ reason: StaleThreadReason, for draft: Draft) {
        pendingStaleWarnings[draft.identity] = reason
        approvalError = Self.draftMessage(for: DraftDispatchError.staleThread(reason))
        recordDraftActivity(.staleWarning, for: draft, staleReason: reason)
    }

    /// Denies (discards) a pending draft without sending or saving it.
    func denyDraft(_ draft: Draft) {
        guard !approvingDraftIDs.contains(draft.identity) else { return }
        approvalError = nil
        pendingStaleWarnings.removeValue(forKey: draft.identity)
        clearOfflineQueueEntry(draft.identity)
        do {
            try removePendingDraft(draft)
            recordDraftActivity(.denied, for: draft)
        } catch {
            approvalError = Self.draftMessage(for: error)
        }
    }

    /// Re-drafts a stale queued reply against the newest related source-thread
    /// message (item 12's "regenerate" option). The old draft remains queued until
    /// the replacement is successfully generated and persisted.
    func regeneratePendingDraft(_ draft: Draft) async {
        guard pendingDrafts.contains(where: { $0.identity == draft.identity }) else { return }
        guard !approvingDraftIDs.contains(draft.identity) else { return }
        guard let mailbox = Self.sourceMailbox(for: draft), mailbox.supportsReplyDrafting else {
            approvalError = Self.draftMessage(for: DraftError.unsupportedSourceMailbox)
            return
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            approvalError = "Connect an email account first."
            return
        }
        guard draftMatchesCurrentAccount(draft, credentials: credentials) else {
            approvalError = "This draft was generated for a different email account."
            return
        }

        approvalError = nil
        approvingDraftIDs.insert(draft.identity)
        defer { approvingDraftIDs.remove(draft.identity) }

        do {
            let source = try await regenerationSource(for: draft, mailbox: mailbox, credentials: credentials)
            _ = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
            guard var replacement = try await makePendingDraft(
                for: source.message,
                mailbox: source.mailbox,
                requireWatching: false,
                credentials: credentials
            ) else {
                approvalError = "The draft could not be regenerated because account settings changed."
                return
            }
            preserveRegenerationProvenance(from: draft, on: &replacement)
            let replacementWarning = await threadStalenessVerdict(
                for: replacement,
                credentials: credentials
            ).reason
            _ = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
            try replacePendingDraft(draft, with: replacement, staleReason: replacementWarning)
        } catch {
            approvalError = Self.draftMessage(for: error)
        }
    }

    /// Rebuilds a preview-sheet draft against the newest related source message.
    /// The preview is not queued; the caller owns the sheet's replacement state.
    func regenerateDraftPreview(_ draft: Draft) async throws -> Draft {
        guard let mailbox = Self.sourceMailbox(for: draft), mailbox.supportsReplyDrafting else {
            throw DraftError.unsupportedSourceMailbox
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            throw DraftDispatchError.missingCredentials
        }
        guard draftMatchesCurrentAccount(draft, credentials: credentials) else {
            if generatedDraft?.identity == draft.identity {
                generatedDraft = nil
            }
            throw DraftDispatchError.accountMismatch
        }

        let source = try await regenerationSource(for: draft, mailbox: mailbox, credentials: credentials)
        _ = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
        guard var replacement = try await makePendingDraft(
            for: source.message,
            mailbox: source.mailbox,
            requireWatching: false,
            credentials: credentials
        ) else {
            throw DraftDispatchError.accountChanged
        }
        _ = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
        preserveRegenerationProvenance(from: draft, on: &replacement)
        generatedDraft = replacement
        return replacement
    }

    /// Routes a native-notification action back into the queue.
    func handleNotificationAction(_ action: DraftNotificationAction, identity: String) async {
        switch action {
        case .open:
            openReviewHandler?()
        case .approve(let sendBehavior):
            guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else { return }
            guard !pendingDraftUncommittedEditIDs.contains(identity) else {
                approvalError = "Review this draft before approving it from a notification; it has unsaved edits."
                openReviewHandler?()
                return
            }
            guard pendingStaleWarnings[identity] == nil else {
                openReviewHandler?()
                return
            }
            await approveDraft(
                draft,
                sendBehavior: sendBehavior,
                surfaceDelayedBlocks: true
            )
            let needsReviewSurface = pendingSendCountdowns[identity] != nil || pendingStaleWarnings[identity] != nil
            if needsReviewSurface {
                openReviewHandler?()
            }
        case .deny:
            guard let draft = pendingDrafts.first(where: { $0.identity == identity }) else { return }
            denyDraft(draft)
        }
    }

    func finalizeApprovedDraft(_ draft: Draft) throws {
        do {
            try recordApprovedDraftIdentity(draft.identity)
            removePendingDraftAfterApproval(draft)
        } catch {
            logger.error("Failed to persist approved draft tombstone: \(error.localizedDescription)")
            try removePendingDraft(draft, removeNotification: false)
        }
        clearOfflineQueueEntry(draft.identity)
        notifier.removeNotification(identity: draft.identity)
    }

    private func recordApprovedDraftIdentity(_ identity: String) throws {
        var approvedDrafts = persistence.loadApprovedDraftIdentities()
        approvedDrafts.insert(identity)
        try persistence.saveApprovedDraftIdentitiesSync(approvedDrafts)
    }

    private func removePendingDraftAfterApproval(_ draft: Draft) {
        guard pendingDrafts.contains(where: { $0.identity == draft.identity }) else { return }
        pendingDrafts.removeAll { $0.identity == draft.identity }
        clearPendingDraftEdits(identity: draft.identity)
        pendingDraftCount = pendingDrafts.count

        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            logger.error("Failed to clean approved draft; tombstone will suppress reload: \(error.localizedDescription)")
        }
    }

    /// Removes a draft from the queue only after the updated queue is durable.
    /// Internal (not `private`) so the one-time pre-gate draft sweep (item 80) can
    /// dequeue a now-skippable draft through the same durable-persistence path.
    @discardableResult
    func removePendingDraft(_ draft: Draft, removeNotification: Bool = true) throws -> Int? {
        let previousDrafts = pendingDrafts
        guard let removalIndex = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else { return nil }
        pendingDrafts.removeAll { $0.identity == draft.identity }
        pendingDraftCount = pendingDrafts.count

        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts = previousDrafts
            pendingDraftCount = previousDrafts.count
            logger.error("Failed to persist pending drafts after removal: \(error.localizedDescription)")
            throw error
        }
        if removeNotification {
            notifier.removeNotification(identity: draft.identity)
        }
        clearPendingDraftEdits(identity: draft.identity)
        return removalIndex
    }

    private func regenerationSource(
        for draft: Draft,
        mailbox: Mailbox,
        credentials: MailAccountCredentials
    ) async throws -> RegenerationSourceMessage {
        let subject = StaleThreadCheck.searchSubject(for: draft.sourceSubject)
        let thread = try await sourceThreadInspectionResult(
            credentials,
            mailbox: mailbox,
            subject: subject,
            draft: draft
        )
        guard let source = StaleThreadCheck.regenerationSource(
            draft: draft,
            threadMessages: thread.messages
        ) else {
            return try await movedRegenerationSource(for: draft, credentials: credentials)
        }
        return RegenerationSourceMessage(message: source, mailbox: mailbox)
    }

    private func movedRegenerationSource(
        for draft: Draft,
        credentials: MailAccountCredentials
    ) async throws -> RegenerationSourceMessage {
        guard let sourceMessageID = StaleThreadCheck.messageIDSearchValue(draft.sourceMessageID) else {
            throw DraftError.sourceMessageUnavailable
        }

        var lastError: Error?
        var searchedMailboxSuccessfully = false
        for mailbox in movedRegenerationSearchMailboxes(for: credentials) {
            do {
                let source = try await movedRegenerationSource(
                    for: draft,
                    credentials: credentials,
                    mailbox: mailbox,
                    sourceMessageID: sourceMessageID
                )
                searchedMailboxSuccessfully = true
                if let source {
                    return source
                }
            } catch {
                lastError = error
            }
        }
        if !searchedMailboxSuccessfully, let lastError {
            throw lastError
        }
        throw DraftError.sourceMessageUnavailable
    }

    private func movedRegenerationSource(
        for draft: Draft,
        credentials: MailAccountCredentials,
        mailbox: Mailbox,
        sourceMessageID: String
    ) async throws -> RegenerationSourceMessage? {
        let source = try await exactHeaderInspectionResult(
            credentials,
            mailbox: mailbox,
            field: "Message-ID",
            value: sourceMessageID
        )
        let replies = await supplementalHeaderInspectionResult(
            credentials,
            mailbox: mailbox,
            seedMessageIDs: [sourceMessageID],
            includeSourceMessages: false
        )
        let thread = Self.mergedInspectionResult(source, replies)
        guard let message = StaleThreadCheck.regenerationSource(
            draft: draft,
            threadMessages: thread.messages,
            requireUIDComparable: false
        ) else {
            return nil
        }
        return RegenerationSourceMessage(message: message, mailbox: mailbox)
    }

    private func movedRegenerationSearchMailboxes(for credentials: MailAccountCredentials) -> [Mailbox] {
        var mailboxes: [Mailbox] = []
        var seen = Set<String>()
        for mailbox in [Mailbox.allMail, .archive] {
            let liveMailbox = Self.liveSearchMailbox(mailbox, credentials: credentials)
            let liveName = liveMailbox.imapName(using: credentials.mailboxNaming).lowercased()
            guard seen.insert(liveName).inserted else { continue }
            mailboxes.append(liveMailbox)
        }
        return mailboxes
    }

    private static func liveSearchMailbox(
        _ mailbox: Mailbox,
        credentials: MailAccountCredentials
    ) -> Mailbox {
        let liveName = mailbox.imapName(using: credentials.mailboxNaming)
        return liveName == mailbox.imapName ? mailbox : .named(liveName)
    }

    private func replacePendingDraft(
        _ draft: Draft,
        with replacement: Draft,
        staleReason: StaleThreadReason?
    ) throws {
        let previousDrafts = pendingDrafts
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else { return }
        try ensureReplacementDraftIsAvailable(replacement, replacing: draft)
        pendingDrafts.removeAll {
            $0.identity == draft.identity || $0.identity == replacement.identity
        }
        pendingDrafts.insert(replacement, at: min(index, pendingDrafts.count))
        pendingDraftCount = pendingDrafts.count

        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts = previousDrafts
            pendingDraftCount = previousDrafts.count
            logger.error("Failed to persist regenerated draft: \(error.localizedDescription)")
            throw error
        }

        pendingStaleWarnings.removeValue(forKey: draft.identity)
        pendingStaleWarnings.removeValue(forKey: replacement.identity)
        clearPendingDraftEdits(identity: draft.identity)
        clearPendingDraftEdits(identity: replacement.identity)
        if let staleReason {
            pendingStaleWarnings[replacement.identity] = staleReason
        }
        notifier.removeNotification(identity: draft.identity)
        if replacement.identity != draft.identity {
            notifier.removeNotification(identity: replacement.identity)
        }
        notifier.notify(for: replacement, sendBehavior: sendBehavior)
    }

    private func ensureReplacementDraftIsAvailable(_ replacement: Draft, replacing draft: Draft) throws {
        guard replacement.identity != draft.identity else { return }
        guard !isReplacementDraftUnavailable(replacement) else {
            throw RegenerationReplacementError.alreadyApproved
        }
    }

    private func isReplacementDraftUnavailable(_ replacement: Draft) -> Bool {
        approvingDraftIDs.contains(replacement.identity)
            || persistence.loadApprovedDraftIdentities().contains(replacement.identity)
    }

    func draftDispatchCredentialsStillCurrent(
        _ expectedCredentials: MailAccountCredentials,
        for draft: Draft
    ) throws -> MailAccountCredentials {
        let credentials = mailCredentials
        guard credentials.isComplete else {
            throw DraftDispatchError.missingCredentials
        }
        guard credentials == expectedCredentials else {
            throw DraftDispatchError.accountChanged
        }
        guard draftMatchesCurrentAccount(draft, credentials: credentials) else {
            throw DraftDispatchError.accountMismatch
        }
        guard draftSourceAllowsReplyDispatch(draft) else {
            throw DraftError.unsupportedSourceMailbox
        }
        return credentials
    }
}
