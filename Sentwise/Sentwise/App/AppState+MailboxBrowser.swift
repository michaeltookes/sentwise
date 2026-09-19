import SentwiseMail
import Foundation

/// The mailbox + criteria used to produce the currently displayed result set.
struct MailboxBrowserQuery: Equatable {
    var mailbox: Mailbox
    var criteria: MailSearchCriteria

    func capped(at maximumUID: UInt32?) -> MailboxBrowserQuery {
        var capped = self
        capped.criteria.maximumUID = maximumUID
        return capped
    }

    func nextPage(after lastUID: UInt32?) -> MailboxBrowserQuery? {
        guard let lastUID, lastUID > 1 else { return nil }
        let cursorMaximumUID = lastUID - 1
        return capped(at: criteria.maximumUID.map { min($0, cursorMaximumUID) } ?? cursorMaximumUID)
    }
}

/// State for the mailbox browser window (item 40): search inputs, one page of
/// results, and paging status. Grouped into a single value so `AppState` stays
/// compact; SwiftUI binds into the individual fields.
struct MailboxBrowserState: Equatable {

    // MARK: Inputs

    /// The connected mailbox the Browse window is pointed at (item 103): the
    /// normalized email of the picked account, or nil to follow the focused
    /// account. Lives here (not on `AppState`) so a full state reset on an
    /// account switch clears it, and browse/search/pagination/cleanup resolve
    /// their credentials through `AppState.browserCredentials`.
    var accountEmail: String?
    var mailbox: Mailbox = .inbox
    var keyword: String = ""
    var sender: String = ""
    var readState: MailReadState = .any
    /// Date filters are opt-in so an untouched browser searches all dates.
    var useSinceFilter = false
    var since = Date()
    var useBeforeFilter = false
    var before = Date()

    // MARK: Results / status

    /// Results accumulated across the pages loaded so far, newest first.
    var results: [MailMessage] = []
    var isSearching = false
    var isLoadingMore = false
    var error: String?
    var hasMore = false
    var totalMatches = 0
    /// True once at least one search has completed, so the UI can tell "no
    /// search yet" from "no matches".
    var hasSearched = false
    /// Query that produced `results`; used so pagination and row actions remain
    /// attached to those rows even if the editable controls change afterward.
    var resultQuery: MailboxBrowserQuery?
    /// Mailbox size captured with the first unfiltered sequence page. Later
    /// pages use this snapshot so new/deleted messages do not shift the range.
    var sequenceSnapshotMessageCount: Int?
    /// Next sequence-number page offset within `sequenceSnapshotMessageCount`.
    var sequencePageOffset = 0

    /// UIDs of rows the user explicitly checked (item 47). When non-empty, bulk
    /// cleanup acts on exactly these messages instead of the whole filter, which
    /// is what makes "just these three" possible. Cleared whenever the result set
    /// is replaced, so a checked UID can never outlive the rows it referred to.
    var selectedMessageIDs: Set<UInt32> = []

    /// The loaded rows the user has checked, newest first.
    var selectedMessages: [MailMessage] {
        results.filter { selectedMessageIDs.contains($0.id) }
    }

    /// True when cleanup should act on the checked rows rather than the filter.
    var hasSelection: Bool {
        !selectedMessages.isEmpty
    }

    /// Whether every loaded row is checked.
    var areAllLoadedSelected: Bool {
        !results.isEmpty && selectedMessageIDs.count >= results.count
            && results.allSatisfy { selectedMessageIDs.contains($0.id) }
    }

    mutating func toggleSelection(_ id: UInt32) {
        if selectedMessageIDs.contains(id) {
            selectedMessageIDs.remove(id)
        } else {
            selectedMessageIDs.insert(id)
        }
    }

    mutating func selectAllLoaded() {
        selectedMessageIDs = Set(results.map(\.id))
    }

    mutating func clearSelection() {
        selectedMessageIDs.removeAll()
    }

    /// The IMAP search criteria described by the current inputs.
    var criteria: MailSearchCriteria {
        MailSearchCriteria(
            text: Self.trimmedOrNil(keyword),
            from: Self.trimmedOrNil(sender),
            since: useSinceFilter ? since : nil,
            before: useBeforeFilter ? before : nil,
            readState: readState
        )
    }

    /// The mailbox search described by the current inputs.
    var query: MailboxBrowserQuery {
        MailboxBrowserQuery(mailbox: mailbox, criteria: criteria)
    }

    private static func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Mailbox-browser actions on `AppState` (item 40). Kept in a separate file so
/// `AppState` stays within the file/type length limits. Each request is guarded
/// by a monotonic generation counter so a stale completion (after an account
/// change or a newer search) never clobbers current state.
extension AppState {

    /// How many results each search page fetches.
    static let mailboxBrowserPageSize = 25

    /// Runs a fresh search from the first page using the current browser inputs.
    func runMailboxSearch() async {
        let requestGeneration = nextBrowserGeneration()
        let query = browser.query
        browser.error = nil
        browser.results = []
        browser.resultQuery = nil
        browser.sequenceSnapshotMessageCount = nil
        browser.sequencePageOffset = 0
        browser.hasMore = false
        browser.totalMatches = 0
        browser.isLoadingMore = false
        // A checked UID refers to a row in the old result set; keeping it across
        // a new search could act on a message the user can no longer see.
        browser.clearSelection()

        let credentials = browserCredentials
        guard credentials.isComplete else {
            browser.error = "Connect an account first."
            browser.hasSearched = true
            return
        }

        browser.isSearching = true
        defer {
            if browserGeneration == requestGeneration {
                browser.isSearching = false
                browser.hasSearched = true
            }
        }

        do {
            let result = try await fetchBrowserPage(query, credentials: credentials, offset: 0)
            guard isCurrentBrowserRequest(requestGeneration, credentials: credentials) else { return }
            browser.results = result.messages
            // The unfiltered view pages by offset (sequence numbers), so its
            // query needs no UID ceiling. Instead, snapshot the mailbox size so
            // later bounded FETCH ranges stay stable if messages arrive/delete.
            if query.criteria.isEmpty {
                browser.resultQuery = query
                browser.sequenceSnapshotMessageCount = result.totalMatches
                browser.sequencePageOffset = result.offset + Self.mailboxBrowserPageSize
            } else {
                // Filtered search pins a UID high-water mark so later pages stay
                // stable as new matching mail arrives.
                browser.resultQuery = query.capped(at: result.messages.map(\.id).max())
            }
            browser.hasMore = result.hasMore
            browser.totalMatches = result.totalMatches
        } catch {
            guard isCurrentBrowserRequest(requestGeneration, credentials: credentials) else { return }
            browser.error = Self.message(for: error)
        }
    }

    /// Loads and appends the next page of results (pagination). No-op unless a
    /// prior search reported more results and nothing else is in flight.
    func loadMoreMailboxResults() async {
        guard browser.hasMore, !browser.isSearching, !browser.isLoadingMore else { return }
        guard let query = browser.resultQuery else { return }

        // Unfiltered view pages by offset (bounded sequence fetch, item 45);
        // filtered search pages by lowering the UID ceiling.
        let pageQuery: MailboxBrowserQuery
        let offset: Int
        let snapshotMessageCount: Int?
        if query.criteria.isEmpty {
            pageQuery = query
            offset = browser.sequencePageOffset
            snapshotMessageCount = browser.sequenceSnapshotMessageCount
        } else {
            guard let next = query.nextPage(after: browser.results.last?.id) else {
                browser.hasMore = false
                return
            }
            pageQuery = next
            offset = 0
            snapshotMessageCount = nil
        }

        let requestGeneration = browserGeneration
        let loadedCount = browser.results.count

        let credentials = browserCredentials
        guard credentials.isComplete else { return }

        browser.error = nil
        browser.isLoadingMore = true
        defer {
            if browserGeneration == requestGeneration {
                browser.isLoadingMore = false
            }
        }

        do {
            let result = try await fetchBrowserPage(
                pageQuery,
                credentials: credentials,
                offset: offset,
                snapshotMessageCount: snapshotMessageCount
            )
            guard isCurrentBrowserRequest(requestGeneration, credentials: credentials) else { return }
            browser.error = nil
            if query.criteria.isEmpty {
                appendUniqueBrowserResults(result.messages)
                browser.sequencePageOffset = offset + Self.mailboxBrowserPageSize
                browser.hasMore = result.hasMore
                browser.totalMatches = browser.sequenceSnapshotMessageCount ?? result.totalMatches
            } else {
                browser.results.append(contentsOf: result.messages)
                browser.hasMore = result.hasMore
                browser.totalMatches = loadedCount + result.totalMatches
            }
        } catch {
            guard isCurrentBrowserRequest(requestGeneration, credentials: credentials) else { return }
            browser.error = Self.message(for: error)
        }
    }

    /// Fetches one browser page, choosing the bounded sequence-fetch path for the
    /// unfiltered "recent mail" view (item 45 — never issues an unbounded
    /// `UID SEARCH`) and UID-search paging for filtered queries. `offset` is only
    /// used by the unfiltered path; filtered paging is driven by the query's own
    /// UID ceiling.
    private func fetchBrowserPage(
        _ query: MailboxBrowserQuery,
        credentials: MailAccountCredentials,
        offset: Int,
        snapshotMessageCount: Int? = nil
    ) async throws -> MailSearchResult {
        if query.criteria.isEmpty {
            return try await mailProvider.fetchMessagePage(
                credentials,
                mailbox: query.mailbox,
                offset: offset,
                limit: Self.mailboxBrowserPageSize,
                snapshotMessageCount: snapshotMessageCount
            )
        }
        return try await mailProvider.searchMessages(
            credentials,
            mailbox: query.mailbox,
            criteria: query.criteria,
            offset: 0,
            limit: Self.mailboxBrowserPageSize
        )
    }

    func nextBrowserGeneration() -> Int {
        browserGeneration += 1
        return browserGeneration
    }

    /// Clears the browser and invalidates any in-flight request when the
    /// connected account changes.
    func resetMailboxBrowserForAccountChange() {
        _ = nextBrowserGeneration()
        browser = MailboxBrowserState()
    }

    private func isCurrentBrowserRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials
    ) -> Bool {
        // Guard on the *browser's* current account (item 103), not the focused
        // account, so switching the Browse-window mailbox invalidates in-flight
        // pages exactly as the generation bump does.
        browserGeneration == requestGeneration && browserCredentials == credentials
    }

    private func appendUniqueBrowserResults(_ messages: [MailMessage]) {
        var seen = Set(browser.results.map(MailboxBrowserMessageIdentity.init))
        let uniqueMessages = messages.filter { message in
            seen.insert(MailboxBrowserMessageIdentity(message)).inserted
        }
        browser.results.append(contentsOf: uniqueMessages)
    }
}

private struct MailboxBrowserMessageIdentity: Hashable {
    let id: UInt32
    let uidValidity: UInt32?
    let messageID: String?

    init(_ message: MailMessage) {
        id = message.id
        uidValidity = message.uidValidity
        messageID = message.messageID
    }
}
