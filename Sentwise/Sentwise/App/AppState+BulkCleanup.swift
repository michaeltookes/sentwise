import SentwiseMail
import Foundation

/// State for the bulk-cleanup panel (item 42): the chosen action, the preview of
/// what it would affect, and progress while it runs.
///
/// `previewQuery`, `previewAccount`, and `preview.selection` are the safety
/// anchors. The user approves a *specific* UID set for a *specific* account, so
/// apply does not sweep in mail that matched after preview.
struct BulkCleanupState: Equatable {
    var action: MailBulkAction = .markRead
    var preview: MailBulkPreview?
    /// The query `preview` was produced from; apply must still match it.
    var previewQuery: MailboxBrowserQuery?
    /// The action `preview` was produced for; action-specific eligibility can differ.
    var previewAction: MailBulkAction?
    /// The non-secret account identity `preview` was produced from.
    var previewAccount: BulkCleanupAccountIdentity?
    var isPreviewing = false
    var isApplying = false
    var progress: MailBulkProgress?
    var error: String?
    var completionMessage: String?

    /// While a multi-pass sweep runs, the running total moved so far. att.net/
    /// Yahoo exposes only ~10,000 messages over IMAP at once, so clearing a large
    /// filter takes repeated passes as older mail becomes visible; the total is
    /// unknown up front, so this is an ever-growing count rather than N-of-M
    /// progress (item 49).
    var sweepMovedSoFar: Int?

    /// Whether a multi-pass sweep is currently running.
    var isSweeping: Bool { sweepMovedSoFar != nil }

    /// Whether the user asked an active sweep to stop after the current pass.
    var isCancellingSweep = false

    /// Whether a confirmed apply is currently allowed.
    var canApply: Bool {
        guard let preview, previewQuery != nil, previewAction == action, previewAccount != nil else { return false }
        return preview.matchCount > 0 && !isPreviewing && !isApplying
    }

    /// Whether any cleanup work is in flight.
    var isBusy: Bool {
        isPreviewing || isApplying
    }

    /// Clears everything derived from a previous run.
    mutating func reset() {
        preview = nil
        previewQuery = nil
        previewAction = nil
        previewAccount = nil
        progress = nil
        sweepMovedSoFar = nil
        isCancellingSweep = false
        error = nil
        completionMessage = nil
    }
}

/// Non-secret account identity used to bind a preview approval to the account
/// that produced it, without retaining app-password material in UI state.
struct BulkCleanupAccountIdentity: Equatable {
    var email: String
    var host: String
    var port: Int

    init(credentials: MailAccountCredentials) {
        email = credentials.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        port = credentials.port
    }
}

struct BulkCleanupApplyContext {
    var previewQuery: MailboxBrowserQuery
    var criteria: MailSearchCriteria
    var preview: MailBulkPreview
    var action: MailBulkAction
    var previewAccount: BulkCleanupAccountIdentity
    var credentials: MailAccountCredentials
}

/// Bulk-cleanup actions on `AppState` (item 42). Kept in a separate file so
/// `AppState` stays within the file/type length limits.
extension AppState {

    /// How many matches a preview lists for the user to eyeball.
    static let bulkPreviewSampleSize = 25

    /// Ceiling on how many messages a single cleanup pass touches.
    static let bulkSelectionCap = 5_000

    var canApplyBulkCleanup: Bool {
        bulk.canApply && bulk.previewQuery == browser.query
    }

    var bulkSelectionArchiveUnavailable: Bool {
        guard let mailbox = browser.resultQuery?.mailbox else { return false }
        return Self.archiveActionMovesToSameMailbox(
            bulk.action,
            source: mailbox,
            naming: connectedMailboxNaming
        )
    }

    /// Scans the mailbox for what the current filter would affect. Read-only.
    func previewBulkCleanup() async {
        let requestGeneration = nextBulkGeneration()
        let query = browser.query
        let action = bulk.action
        bulk.reset()

        let credentials = browserCredentials
        guard credentials.isComplete else {
            bulk.error = "Connect an account first."
            return
        }
        guard let criteria = Self.bulkCleanupCriteria(for: query.criteria, action: action) else {
            bulk.error = "Mark read only applies to unread messages."
            return
        }

        bulk.isPreviewing = true
        defer {
            if bulkGeneration == requestGeneration {
                bulk.isPreviewing = false
            }
        }

        do {
            let preview = try await mailProvider.previewBulkCleanup(
                credentials,
                mailbox: query.mailbox,
                criteria: criteria,
                sampleLimit: Self.bulkPreviewSampleSize,
                selectionCap: Self.bulkSelectionCap
            )
            guard isCurrentBulkCleanupRequest(requestGeneration, credentials: credentials) else { return }
            bulk.preview = preview
            bulk.previewQuery = query
            bulk.previewAction = action
            bulk.previewAccount = BulkCleanupAccountIdentity(credentials: credentials)
        } catch {
            guard isCurrentBulkCleanupRequest(requestGeneration, credentials: credentials) else { return }
            bulk.error = Self.message(for: error)
        }
    }

    /// Applies the action to just the rows the user checked (item 47).
    ///
    /// Checked rows need no server scan to preview — the user is looking at
    /// exactly the messages they picked, which *is* the preview. So this stages
    /// them as the approved selection and hands off to the same validated apply
    /// path, inheriting its account/query/action checks and its guarantee that
    /// only the approved UID set is touched.
    func applyBulkCleanupToSelectedMessages() async {
        let credentials = browserCredentials
        guard credentials.isComplete else {
            bulk.error = "Connect an account first."
            return
        }

        let selected = browser.selectedMessages
        guard !selected.isEmpty else {
            bulk.error = "Check at least one message first."
            return
        }
        guard let mailbox = browser.resultQuery?.mailbox else {
            bulk.error = "Search the mailbox before cleaning up specific messages."
            return
        }
        guard !Self.archiveActionMovesToSameMailbox(
            bulk.action,
            source: mailbox,
            naming: credentials.mailboxNaming
        ) else {
            bulk.error = Self.bulkArchiveUnavailableMessage
            return
        }

        bulk.error = nil
        bulk.completionMessage = nil
        bulk.preview = MailBulkPreview(
            matchCount: selected.count,
            sample: selected,
            isPartial: false,
            selection: MailBulkSelection(
                uidValidity: selected.compactMap(\.uidValidity).first,
                uids: selected.map(\.id)
            )
        )
        // Anchor approval to the mailbox the rows actually came from, not the
        // live folder picker, so switching folders mid-flow invalidates it.
        bulk.previewQuery = MailboxBrowserQuery(mailbox: mailbox, criteria: browser.criteria)
        bulk.previewAction = bulk.action
        bulk.previewAccount = BulkCleanupAccountIdentity(credentials: credentials)

        await applyBulkCleanup()
    }

    /// Applies the selected action to everything the *previewed* query matched.
    ///
    /// Refuses to run if the search inputs changed since the preview: the user
    /// approved a specific set of messages, so a changed filter must be
    /// re-previewed rather than silently acted on.
    func applyBulkCleanup() async {
        guard let applyContext = validatedBulkApplyContext() else { return }

        let requestGeneration = nextBulkGeneration()
        let action = applyContext.action
        bulk.error = nil
        bulk.completionMessage = nil
        bulk.isApplying = true
        bulk.progress = MailBulkProgress(processed: 0, total: applyContext.preview.matchCount)
        defer {
            if bulkGeneration == requestGeneration {
                bulk.isApplying = false
            }
        }

        do {
            let result = try await mailProvider.applyBulkCleanup(
                applyContext.credentials,
                mailbox: applyContext.previewQuery.mailbox,
                criteria: applyContext.criteria,
                action: action,
                selection: applyContext.preview.selection,
                selectionCap: Self.bulkSelectionCap,
                // Batches complete on a NIO event loop, so hop back to the main
                // actor before touching published state.
                onProgress: { [weak self, previewAccount = applyContext.previewAccount] progress in
                    Task { @MainActor in
                        self?.updateBulkApplyProgress(
                            progress,
                            requestGeneration,
                            account: previewAccount
                        )
                    }
                }
            )
            guard isCurrentBulkCleanupApply(requestGeneration, account: applyContext.previewAccount) else { return }
            await finishBulkApply(result)
        } catch {
            guard isCurrentBulkCleanupApply(requestGeneration, account: applyContext.previewAccount) else { return }
            bulk.error = Self.message(for: error)
        }
    }

    func nextBulkGeneration() -> Int {
        bulkGeneration += 1
        return bulkGeneration
    }

    func resetBulkCleanupForAccountChange() {
        _ = nextBulkGeneration()
        bulk.reset()
        bulk.isPreviewing = false
        bulk.isApplying = false
    }

    /// Human-readable summary of a completed run.
    static func bulkCompletionMessage(for result: MailBulkResult) -> String {
        let noun = result.affectedCount == 1 ? "message" : "messages"
        switch result.action {
        case .markRead:
            return "Marked \(result.affectedCount) \(noun) as read."
        case .archive:
            return "Archived \(result.affectedCount) \(noun)."
        case .moveToTrash:
            return "Moved \(result.affectedCount) \(noun) to Trash."
        }
    }

    /// The confirmation question shown before a destructive run. `account` names
    /// the picked mailbox (item 103) so a multi-account user sees exactly which
    /// mailbox is about to be swept; nil (single account) omits the naming.
    static func bulkConfirmationMessage(
        for action: MailBulkAction,
        matchCount: Int,
        isPartial: Bool,
        account: String? = nil
    ) -> String {
        // Name the scope, not just the count. The browser lists one page at a
        // time ("Showing 25 of 605"), so a bare count reads as "the 25 I can
        // see" — a dangerous misreading for a destructive action.
        let noun = matchCount == 1 ? "message" : "messages"
        let inMailbox = Self.bulkAccountClause(account)
        let subject: String
        if isPartial {
            subject = "at least \(matchCount) \(noun)\(inMailbox) matching this filter"
        } else if matchCount == 1 {
            subject = "1 \(noun)\(inMailbox) matching this filter"
        } else {
            subject = "all \(matchCount) \(noun)\(inMailbox) matching this filter"
        }

        // Move actions sweep until the mailbox is clear, so the true total may
        // exceed the currently-visible count on a provider that only exposes a
        // slice of a huge mailbox at a time (item 49).
        let sweepNote = " This runs in repeated passes until every match is"
            + " gone, so it may move more than the \(matchCount) visible now."

        switch action {
        case .markRead:
            return "Mark \(subject) as read?"
        case .archive:
            return "Archive \(subject)?\(sweepNote) You can find them in the Archive folder."
        case .moveToTrash:
            return "Move \(subject) to Trash?\(sweepNote) You can recover them from Trash."
        }
    }

    /// The confirmation question for a checked-rows cleanup (item 47). Scope is
    /// the specific messages picked, so this must not say "matching this filter"
    /// — that would overstate what is about to happen. `account` names the picked
    /// mailbox (item 103); nil (single account) omits it.
    static func bulkSelectionConfirmationMessage(
        for action: MailBulkAction,
        count: Int,
        account: String? = nil
    ) -> String {
        let noun = count == 1 ? "message" : "messages"
        let subject = "\(count) checked \(noun)\(Self.bulkAccountClause(account))"
        switch action {
        case .markRead:
            return "Mark \(subject) as read?"
        case .archive:
            return "Archive \(subject)? You can find them in the Archive folder."
        case .moveToTrash:
            return "Move \(subject) to Trash? You can recover them from Trash."
        }
    }

    /// The " in <mailbox>" clause naming the picked account in bulk-cleanup
    /// confirmation copy (item 103), or an empty string when unset (single
    /// account). Trimmed/blank emails yield no clause so copy never dangles.
    static func bulkAccountClause(_ account: String?) -> String {
        guard let account = account?.trimmingCharacters(in: .whitespacesAndNewlines),
              !account.isEmpty else { return "" }
        return " in \(account)"
    }

    static let bulkArchiveUnavailableMessage =
        "Archive is unavailable because the source and archive folders are the same."

    static func archiveActionMovesToSameMailbox(
        _ action: MailBulkAction,
        source: Mailbox,
        naming: MailboxNaming
    ) -> Bool {
        guard action == .archive, let destination = action.destination else { return false }
        return source.imapName(using: naming) == destination.imapName(using: naming)
    }

    func validatedBulkApplyContext() -> BulkCleanupApplyContext? {
        guard let previewQuery = bulk.previewQuery,
              let preview = bulk.preview,
              let previewAction = bulk.previewAction,
              let previewAccount = bulk.previewAccount else {
            bulk.error = "Preview the cleanup before running it."
            return nil
        }
        let credentials = browserCredentials
        guard credentials.isComplete else {
            bulk.reset()
            bulk.error = "Connect an account first."
            return nil
        }
        guard previewAccount == BulkCleanupAccountIdentity(credentials: credentials) else {
            bulk.reset()
            bulk.error = "The connected account changed since the preview. Preview again before running cleanup."
            return nil
        }
        guard previewQuery == browser.query else {
            bulk.reset()
            bulk.error = "The search changed since the preview. Preview again before running cleanup."
            return nil
        }
        guard previewAction == bulk.action else {
            bulk.reset()
            bulk.error = "The cleanup action changed since the preview. Preview again before running cleanup."
            return nil
        }
        guard let criteria = Self.bulkCleanupCriteria(for: previewQuery.criteria, action: previewAction) else {
            bulk.reset()
            bulk.error = "Mark read only applies to unread messages."
            return nil
        }
        guard preview.matchCount > 0 else {
            bulk.error = "Nothing matches that filter."
            return nil
        }
        guard preview.selection != nil else {
            bulk.reset()
            bulk.error = "Preview the cleanup again before running cleanup."
            return nil
        }
        return BulkCleanupApplyContext(
            previewQuery: previewQuery,
            criteria: criteria,
            preview: preview,
            action: previewAction,
            previewAccount: previewAccount,
            credentials: credentials
        )
    }

    static func bulkCleanupCriteria(
        for criteria: MailSearchCriteria,
        action: MailBulkAction
    ) -> MailSearchCriteria? {
        guard action == .markRead else { return criteria }
        return criteria.markReadCandidateCriteria()
    }

    private func updateBulkApplyProgress(
        _ progress: MailBulkProgress,
        _ requestGeneration: Int,
        account: BulkCleanupAccountIdentity
    ) {
        guard isCurrentBulkCleanupApply(requestGeneration, account: account) else { return }
        bulk.progress = progress
    }

    private func finishBulkApply(_ result: MailBulkResult) async {
        bulk.progress = MailBulkProgress(
            processed: result.affectedCount,
            total: result.affectedCount
        )
        bulk.completionMessage = Self.bulkCompletionMessage(for: result)
        // The affected messages have moved or changed state, so the visible
        // result set is stale — reload it rather than showing phantom rows.
        bulk.preview = nil
        bulk.previewQuery = nil
        bulk.previewAction = nil
        bulk.previewAccount = nil
        await runMailboxSearch()
    }

    private func isCurrentBulkCleanupRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials
    ) -> Bool {
        bulkGeneration == requestGeneration && browserCredentials == credentials
    }

    func isCurrentBulkCleanupApply(
        _ requestGeneration: Int,
        account: BulkCleanupAccountIdentity
    ) -> Bool {
        bulkGeneration == requestGeneration
            && BulkCleanupAccountIdentity(credentials: browserCredentials) == account
    }
}
