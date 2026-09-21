import SentwiseMail
import Foundation
import os

private let policyLogger = Logger(subsystem: "com.tookes.Sentwise", category: "InboxDraftingPolicy")

enum AutoDraftBudgetReservationError: Error, Equatable {
    case exhausted
}

/// The tier-gated inbox-drafting policy on `AppState` (item 108): the Starter
/// watcher gate, the draft-on-click default, the opt-in automatic-drafting
/// decision (global toggle + auto-draft sender list), the monthly auto-draft
/// budget cap, and the reauth re-baseline.
///
/// **Enforcement posture (accepted A-L5, per `docs/tier-matrix.md`):** these are
/// client-side *spend-intent* gates keyed off `subscription.plan` from `/v1/me`,
/// exactly like the account-count gate. A source-builder can bypass a client
/// gate and open core accepts this; the managed proxy meters and enforces the
/// draft allotment server-side regardless. This file changes *when the app
/// chooses to spend*, not whether spending is allowed.
extension AppState {

    // MARK: - Tier gate (Starter has no inbox watcher)

    /// Whether the inbox watcher may run for the current subscription tier.
    /// Starter never watches (no reply-worthiness gate, no notifications, no
    /// background token burn); Pro/Unlimited/Trial do. Unknown/offline/none is
    /// lenient (Pro-equivalent) so a briefly-offline paid user is not stranded.
    var inboxWatchingAllowedForTier: Bool {
        InboxDraftingTierPolicy.allowsInboxWatching(for: currentSubscriptionPlan)
    }

    /// Whether the opt-in automatic-drafting controls are offered for the current
    /// tier (Pro/Unlimited/Trial; the lenient default also offers them).
    var offersAutomaticDrafting: Bool {
        InboxDraftingTierPolicy.offersAutomaticDrafting(for: currentSubscriptionPlan)
    }

    /// The message shown where the per-account watch status normally appears when
    /// the tier has no inbox watcher (Starter).
    static let inboxWatchingProFeatureMessage = "Inbox watching is a Pro feature"

    /// Stops any running watchers when the tier no longer permits inbox watching —
    /// e.g. a live downgrade to Starter observed on a `/v1/me` refresh. Manual
    /// on-demand drafting from Browse/preview is unaffected.
    func enforceInboxWatchingTierGate() {
        guard !inboxWatchingAllowedForTier else { return }
        guard watchStatus != .idle ||
                resumeWatchingAfterManagedReauth ||
                backgroundConnectedAccounts.contains(where: {
                    $0.watchStatus != .idle || $0.resumeWatchingAfterManagedReauth
                }) else {
            return
        }
        policyLogger.info("Stopping inbox watchers; current tier does not permit inbox watching")
        let shouldResumeFocusedWatcher = watchStatus == .watching || resumeWatchingAfterManagedReauth
        let backgroundAccountsToResume = backgroundConnectedAccounts.filter {
            $0.watchStatus == .watching || $0.resumeWatchingAfterManagedReauth
        }
        stopWatching(cancelCountdowns: false)
        if shouldResumeFocusedWatcher {
            resumeWatchingAfterManagedReauth = true
        }
        stopAllBackgroundWatchers(cancelCountdowns: false)
        for account in backgroundAccountsToResume {
            account.resumeWatchingAfterManagedReauth = true
        }
    }

    // MARK: - Draft-on-click vs. automatic drafting

    /// Whether a reply-worthy message should be auto-generated now (spending a
    /// managed credit) rather than enqueued as an awaiting-request entry for the
    /// user to draft on click. Auto happens when the sender is on the auto-draft
    /// list, or the global auto toggle is on — unless the monthly auto-draft budget
    /// is exhausted, which falls back to draft-on-click (and fires the cap alert
    /// once per window).
    func shouldAutoGenerateWatcherDraft(for message: MailMessage) -> Bool {
        guard offersAutomaticDrafting else { return false }
        let wantsAuto = inboxDrafting.autoDraftEnabled
            || SenderRules.matches(senderEmail: message.from?.email, in: inboxDrafting.autoDraftSenders)
        guard wantsAuto else { return false }
        if isAutoDraftBudgetExhausted {
            fireAutoDraftBudgetAlertIfNeeded()
            return false
        }
        return true
    }

    // MARK: - Awaiting-request (draft-on-click) entries

    /// Enqueues a reply-worthy message as an undrafted "awaiting request" entry
    /// (item 108 draft-on-click): it notifies the user with an offer and adds a
    /// Draft-button row to Review Drafts. No LLM call is made and no credit spent —
    /// generation happens only when the user clicks Draft. Activity history is not
    /// recorded for the offer (no draft was created); the notification is the signal.
    func enqueueAwaitingRequestDraft(
        for message: MailMessage,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) throws {
        let entry = Draft(
            id: message.id,
            sourceUIDValidity: message.uidValidity,
            sourceAccountEmail: credentials.email,
            sourceMailHost: credentials.host,
            sourceMailPort: credentials.port,
            sourceMailbox: mailbox.imapName,
            sourceSubject: message.subject,
            sourceFrom: message.from,
            sourceReplyTo: message.replyTo,
            sourceMessageID: message.messageID,
            replySubject: Self.replySubject(for: message.subject),
            body: "",
            model: "",
            generatedAt: Date(),
            awaitingRequest: DraftAwaitingRequest()
        )
        try enqueuePendingDraft(entry, recordActivity: false)
    }

    /// Enqueues a reply-worthy message as a draft-on-click awaiting-request entry
    /// during a watcher poll (item 108) and marks it handled so the watcher does
    /// not re-offer it. No LLM call is made and no credit spent. Left unprocessed
    /// on a persistence failure so the next poll retries. Re-validates the poll
    /// context first, like the generate path, so a late enqueue can't cross an
    /// account/erase boundary.
    func enqueueAwaitingRequestWatcherEntry(
        _ message: MailMessage,
        account: ConnectedMailAccount?,
        credentials: MailAccountCredentials,
        mailbox: Mailbox,
        localDataGeneration: UInt64
    ) {
        guard isCurrentWatcherPoll(
            localDataGeneration: localDataGeneration,
            credentials: credentials,
            account: account
        ) else { return }
        do {
            try enqueueAwaitingRequestDraft(for: message, credentials: credentials, mailbox: mailbox)
            markProcessed(message, account: credentials.email, mailbox: mailbox)
            DiagnosticLog.verbose("Inbox watcher enqueued reply-worthy message for draft-on-click")
        } catch {
            policyLogger.error("Failed to enqueue awaiting-request draft: \(error.localizedDescription)")
        }
    }

    /// Generates a real reply for an awaiting-request entry when the user clicks
    /// Draft (item 108). Fetches the source message and drafts in the account's
    /// voice — the single point where an on-click reply spends a managed credit —
    /// then replaces the awaiting entry with the generated draft. A no-op if the
    /// entry is gone, already generating, or its account is no longer connected.
    func draftAwaitingRequest(_ draft: Draft) async {
        guard draft.isAwaitingDraftRequest,
              pendingDrafts.contains(where: { $0.identity == draft.identity }),
              !approvingDraftIDs.contains(draft.identity) else { return }
        approvalError = nil
        let credentials: MailAccountCredentials
        do {
            credentials = try dispatchCredentials(forDraft: draft)
        } catch {
            approvalError = Self.draftMessage(for: error)
            return
        }
        guard isLLMConnected, currentLLMProviderAllowsRequests || canAttemptStaleManagedLicenseRefresh else {
            approvalError = "Connect an AI provider first."
            return
        }
        guard let mailbox = Self.sourceMailbox(for: draft), mailbox.supportsReplyDrafting else {
            approvalError = Self.draftMessage(for: DraftError.unsupportedSourceMailbox)
            return
        }
        approvingDraftIDs.insert(draft.identity)
        defer { approvingDraftIDs.remove(draft.identity) }
        do {
            guard let generated = try await makePendingDraft(
                for: Self.reconstructedSourceMessage(from: draft),
                mailbox: mailbox,
                requireWatching: false,
                credentials: credentials
            ) else {
                approvalError = "The draft could not be generated because account settings changed."
                return
            }
            try replacePendingDraft(draft, with: generated, staleReason: nil)
            recordDraftActivity(.draftCreated, for: generated)
        } catch {
            approvalError = Self.draftMessage(for: error)
        }
    }

    /// Dismisses a reply-worthy awaiting-request entry without drafting (item 108):
    /// removes it from Review Drafts. The source message was already marked handled
    /// when the entry was enqueued, so the watcher never re-offers it. Distinct
    /// from denying a generated draft — no reply was produced, so there is no reason
    /// picker or feedback record.
    func dismissAwaitingRequestDraft(_ draft: Draft) {
        guard draft.isAwaitingDraftRequest else { return }
        do {
            try removePendingDraft(draft)
        } catch {
            approvalError = Self.draftMessage(for: error)
        }
    }

    /// Rebuilds the minimal source message an awaiting-request entry needs to
    /// re-fetch its body and generate. `date` is display-only and unused by the
    /// draft pipeline, so an empty value is safe.
    static func reconstructedSourceMessage(from draft: Draft) -> MailMessage {
        MailMessage(
            id: draft.id,
            uidValidity: draft.sourceUIDValidity,
            from: draft.sourceFrom,
            replyTo: draft.sourceReplyTo,
            subject: draft.sourceSubject,
            date: "",
            messageID: draft.sourceMessageID
        )
    }

    // MARK: - Monthly auto-draft budget cap

    /// The current budget window (the managed allotment reset instant), or nil when
    /// unknown — in which case the cap is not enforced (lenient, like the offline
    /// tier default), so an unknown window never wrongly strands auto-drafting.
    private var autoDraftBudgetWindow: Date? {
        guard let resetsAt = managedQuota?.resetsAt, resetsAt > .distantPast else { return nil }
        return resetsAt
    }

    /// The count of automatic watcher draft-generation calls recorded in the
    /// current window.
    var autoDraftUsedThisWindow: Int {
        guard let window = autoDraftBudgetWindow,
              let state = autoDraftBudgetStore.loadState(for: currentManagedUsageAccountKey),
              state.windowResetsAt == window,
              state.accountKey == currentManagedUsageAccountKey else { return 0 }
        return state.used
    }

    /// Whether auto-drafting has reached its monthly call budget and must fall
    /// back to draft-on-click. `false` when no cap is set or the window is unknown.
    var isAutoDraftBudgetExhausted: Bool {
        guard let cap = inboxDrafting.monthlyAutoDraftBudget, autoDraftBudgetWindow != nil else { return false }
        return autoDraftUsedThisWindow >= max(0, cap)
    }

    /// Atomically claims one automatic watcher draft-generation slot before the
    /// LLM call begins. Returning `false` means another watcher already claimed the
    /// final slot (or the cap was already exhausted), so the caller must fall back
    /// to draft-on-click without spending.
    func reserveAutoDraftBudgetUsageIfAvailable() -> Bool {
        guard let cap = inboxDrafting.monthlyAutoDraftBudget,
              let window = autoDraftBudgetWindow else {
            return true
        }
        let normalizedCap = max(0, cap)
        let key = currentManagedUsageAccountKey
        var state = currentAutoDraftBudgetState(window: window, key: key)
        guard state.used < normalizedCap else {
            fireAutoDraftBudgetAlertIfNeeded()
            return false
        }
        state.used += 1
        autoDraftBudgetStore.save(state)
        return true
    }

    private func fireAutoDraftBudgetAlertIfNeeded() {
        guard !ProwlHuntRuntime.current.isEnabled,
              let window = autoDraftBudgetWindow,
              let cap = inboxDrafting.monthlyAutoDraftBudget else { return }
        let key = currentManagedUsageAccountKey
        let state = currentAutoDraftBudgetState(window: window, key: key)
        guard !state.capAlertFired else { return }
        var fired = state
        fired.capAlertFired = true
        autoDraftBudgetStore.save(fired)
        notifier.notifyUsageAlert(Self.autoDraftBudgetAlert(cap: cap, window: window, accountKey: key))
    }

    private func currentAutoDraftBudgetState(window: Date, key: String) -> AutoDraftBudgetState {
        if let existing = autoDraftBudgetStore.loadState(for: key),
           existing.windowResetsAt == window,
           existing.accountKey == key {
            return existing
        }
        return AutoDraftBudgetState(accountKey: key, windowResetsAt: window)
    }

    static func autoDraftBudgetAlert(cap: Int, window: Date, accountKey: String) -> UsageAlert {
        let windowString = ManagedQuotaDate.string(from: window)
        return UsageAlert(
            identifier: "auto-draft-budget-\(accountKey)-\(windowString)",
            title: "Auto-drafting paused for this month",
            body: "You've reached your \(cap)-draft auto-drafting budget. Reply-worthy mail waits for "
                + "you to click Draft until your allotment resets.",
            threshold: .hundred
        )
    }

    // MARK: - Reauth re-baseline

    /// Re-baselines the inbox before a watcher resumes after a managed sign-in or
    /// reauth (item 108): the resumed watcher treats "now" as the new baseline and
    /// drops the backlog that accumulated while signed out, instead of replaying it
    /// as a draft burst (the 2026-09-21 catch-up burst). Mirrors how the initial
    /// baseline suppresses pre-existing mail.
    func rebaselineInboxForManagedReauth(account: ConnectedMailAccount?) {
        let email = (account?.credentials.email ?? mailCredentials.email)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }
        processedMessages.resetBaseline(account: email, mailbox: .inbox)
        persistence.saveProcessedMessages(processedMessages)
        policyLogger.info("Re-baselined inbox watcher after managed reauth to drop accumulated backlog")
    }
}
