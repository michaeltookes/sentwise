import Foundation

/// Errors surfaced by a `MailProvider`.
public enum MailError: Error, Equatable, Sendable {
    /// Required credential fields are missing.
    case incompleteCredentials
    /// The connection (TCP/TLS) could not be established.
    case connectionFailed(String)
    /// The server rejected the credentials.
    case authenticationFailed(String)
    /// An IMAP command (e.g. SELECT/FETCH) failed.
    case commandFailed(String)
    /// An SMTP command failed with a status code from the server.
    case smtpCommandFailed(code: Int, message: String)
    /// The search matched too many messages to return in one response — the
    /// server's reply exceeded the IMAP frame limit. The caller should narrow
    /// the filter (or use the bounded bulk-selection path). See item 45.
    case resultTooLarge
    /// An SMTP send failed *after* the message body (DATA) was submitted but
    /// before the server confirmed acceptance (a connection drop, timeout, or
    /// I/O error in that window). The outcome is **ambiguous** — the server may
    /// already have queued the message — so this must never be auto-retried
    /// (item 27's no-duplicate-sends invariant). Callers surface it to the user
    /// and leave the draft pending for a manual decision. Failures *before* DATA
    /// submission surface as `connectionFailed` instead and are safe to retry.
    case sendInterruptedAfterSubmission(String)
}

/// A mailbox backend. Exposes a connection check plus recent-message fetch;
/// send is layered on next.
public protocol MailProvider: Sendable {
    /// Connects, authenticates, and disconnects. Throws `MailError` on failure.
    func verifyConnection(_ credentials: MailAccountCredentials) async throws

    /// Fetches up to `limit` of the most recent messages from `mailbox`
    /// (newest first). Envelope-level for now.
    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage]

    /// Fetches the text body of the message identified by `uid` in `mailbox`.
    ///
    /// Uses `BODY.PEEK[TEXT]` so reading the body does not set the `\Seen`
    /// flag. Returns the raw text body as sent by the server (still MIME-
    /// structured for multipart messages); use `MailBodyText.plainText(from:)`
    /// to reduce it to human-readable text. The raw bytes are preserved so MIME
    /// part charsets can be applied before decoding.
    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data

    /// Fetches a bounded set of header fields for the message identified by
    /// `uid` in `mailbox`, using `BODY.PEEK[HEADER.FIELDS (...)]` so reading
    /// them does not set `\Seen`. Carries the list/automation/content-type
    /// signals the ENVELOPE fetch omits, for the reply-worthiness gate (item 17).
    func fetchHeaderFields(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> MailHeaderFields

    /// Searches `mailbox` server-side (IMAP `UID SEARCH`) for messages matching
    /// `criteria`, returning one page of envelope-level results (newest first)
    /// plus the total match count. `offset`/`limit` page through the full match
    /// set so large mailboxes never download in full. Throws `MailError` on
    /// failure.
    func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult

    /// Fetches one page of a mailbox's messages by sequence number (newest
    /// first), returning the page plus the mailbox's total message count. When
    /// `snapshotMessageCount` is set, the page range is calculated against that
    /// first-page count so later pages do not shift when the live mailbox count
    /// changes. Issues no `UID SEARCH`, so the unfiltered "recent mail" view
    /// stays usable on mailboxes of any size (item 45). Throws `MailError` on
    /// failure.
    func fetchMessagePage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        offset: Int,
        limit: Int,
        snapshotMessageCount: Int?
    ) async throws -> MailSearchResult

    /// Reports what a bulk action would affect in `mailbox` for `criteria`,
    /// without changing anything. Selection is bounded, so a very large match set
    /// may be reported as partial. Throws `MailError` on failure.
    func previewBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        sampleLimit: Int,
        selectionCap: Int
    ) async throws -> MailBulkPreview

    /// Applies `action` to every message in `mailbox` matching `criteria`, in
    /// bounded batches, calling `onProgress` after each. Throws `MailError` on
    /// failure.
    func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selection: MailBulkSelection?,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> MailBulkResult

    /// Appends a full RFC 822 message to `mailbox` via IMAP `APPEND`, tagging it
    /// with the given flags (e.g. `\Draft`). Used to save a reply as a draft
    /// without sending it. Throws `MailError` on failure.
    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws

    /// Submits a full RFC 822 message for delivery over SMTP (implicit TLS),
    /// authenticating with the app password or XOAUTH2. `envelope` carries the SMTP-level
    /// sender and recipients (`MAIL FROM` / `RCPT TO`), which need not match the
    /// message's display headers. Throws `MailError` on failure.
    func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws
}

/// The SMTP-level addressing for a message: the return-path sender and the
/// recipients the server should deliver to. Distinct from the display `From:`/
/// `To:` headers in the message body.
public struct SMTPEnvelope: Sendable, Equatable {
    /// The `MAIL FROM` return-path address (bare, no display name).
    public var sender: String
    /// The `RCPT TO` recipient addresses (bare, no display names).
    public var recipients: [String]

    public init(sender: String, recipients: [String]) {
        self.sender = sender
        self.recipients = recipients
    }
}

/// IMAP message flags supported when appending.
public enum MailFlag: Sendable, Equatable {
    case draft
    case seen
}

public extension MailProvider {
    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32
    ) async throws -> Data {
        try await fetchBodyText(
            credentials,
            mailbox: mailbox,
            uid: uid,
            expectedUIDValidity: nil
        )
    }

    /// Default: no header fields available. `IMAPMailProvider` overrides this
    /// with the real `HEADER.FIELDS` fetch; other conformers (test doubles,
    /// non-IMAP backends) inherit empty fields, which the reply-worthiness gate
    /// treats conservatively (when in doubt, draft).
    func fetchHeaderFields(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> MailHeaderFields {
        MailHeaderFields()
    }

    /// Default: sending is unsupported. Providers that can submit mail (e.g.
    /// `IMAPMailProvider` via SMTP) override this; other conformers inherit a
    /// clear failure rather than a compile-time requirement.
    func sendMessage(
        _ credentials: MailAccountCredentials,
        rfc822: Data,
        envelope: SMTPEnvelope
    ) async throws {
        throw MailError.commandFailed("This provider does not support sending mail.")
    }

    /// Default: searching is unsupported. `IMAPMailProvider` overrides this so
    /// other conformers (test doubles, non-IMAP backends) inherit a clear
    /// failure rather than a compile-time requirement.
    func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult {
        throw MailError.commandFailed("This provider does not support searching mail.")
    }

    /// Default: fall back to `searchMessages` with empty criteria. `IMAPMailProvider`
    /// overrides this with the bounded sequence-fetch path; other conformers get
    /// behavior consistent with their search implementation.
    func fetchMessagePage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult {
        try await fetchMessagePage(
            credentials,
            mailbox: mailbox,
            offset: offset,
            limit: limit,
            snapshotMessageCount: nil
        )
    }

    /// Default: fall back to `searchMessages` with empty criteria. `IMAPMailProvider`
    /// overrides this with the bounded sequence-fetch path; other conformers get
    /// behavior consistent with their search implementation.
    func fetchMessagePage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        offset: Int,
        limit: Int,
        snapshotMessageCount: Int?
    ) async throws -> MailSearchResult {
        try await searchMessages(
            credentials,
            mailbox: mailbox,
            criteria: MailSearchCriteria(),
            offset: offset,
            limit: limit
        )
    }

    /// Default: bulk cleanup is unsupported. `IMAPMailProvider` overrides this
    /// with the windowed selection path; other conformers inherit a clear
    /// failure rather than a compile-time requirement.
    func previewBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        sampleLimit: Int,
        selectionCap: Int
    ) async throws -> MailBulkPreview {
        throw MailError.commandFailed("This provider does not support bulk cleanup.")
    }

    /// Default: bulk cleanup is unsupported. See `previewBulkCleanup`.
    func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selection: MailBulkSelection?,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> MailBulkResult {
        throw MailError.commandFailed("This provider does not support bulk cleanup.")
    }

    /// Convenience for callers that intentionally want a live selection rather
    /// than applying a previewed UID set.
    func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> MailBulkResult {
        try await applyBulkCleanup(
            credentials,
            mailbox: mailbox,
            criteria: criteria,
            action: action,
            selection: nil,
            selectionCap: selectionCap,
            onProgress: onProgress
        )
    }
}

/// A read/unread filter for a mailbox search.
public enum MailReadState: Sendable, Equatable, Hashable {
    /// No read-state constraint.
    case any
    /// Only unread messages (IMAP `UNSEEN`).
    case unreadOnly
    /// Only read messages (IMAP `SEEN`).
    case readOnly
}

/// A single IMAP `HEADER` search predicate.
public struct MailHeaderSearch: Sendable, Equatable, Hashable {
    public var field: String
    public var value: String

    public init(field: String, value: String) {
        self.field = field
        self.value = value
    }
}

/// Criteria for a server-side mailbox search. Every set field is combined with
/// `AND`; leaving them all unset matches every message (newest first). Blank
/// text fields are ignored, so an empty search box behaves like "recent mail".
public struct MailSearchCriteria: Sendable, Equatable, Hashable {
    /// Free-text keyword matched against the whole message (IMAP `TEXT`).
    public var text: String?
    /// Matched against the `From` header (IMAP `FROM`).
    public var from: String?
    /// Matched against the `Subject` header (IMAP `SUBJECT`).
    public var subject: String?
    /// Matched against arbitrary message headers (IMAP `HEADER`).
    public var headers: [MailHeaderSearch]
    /// Only messages on/after this calendar day (IMAP `SINCE`).
    public var since: Date?
    /// Only messages before this calendar day (IMAP `BEFORE`).
    public var before: Date?
    /// Read/unread constraint.
    public var readState: MailReadState
    /// Only flagged/starred messages (IMAP `FLAGGED`).
    public var flaggedOnly: Bool
    /// Optional high-water UID, used to keep paged result sets stable when newer
    /// matching messages arrive after the first page was loaded.
    public var maximumUID: UInt32?

    public init(
        text: String? = nil,
        from: String? = nil,
        subject: String? = nil,
        headers: [MailHeaderSearch] = [],
        since: Date? = nil,
        before: Date? = nil,
        readState: MailReadState = .any,
        flaggedOnly: Bool = false,
        maximumUID: UInt32? = nil
    ) {
        self.text = text
        self.from = from
        self.subject = subject
        self.headers = headers
        self.since = since
        self.before = before
        self.readState = readState
        self.flaggedOnly = flaggedOnly
        self.maximumUID = maximumUID
    }

    /// True when no filter is set — the search reduces to "all mail, newest
    /// first". Blank/whitespace-only text fields do not count as a filter.
    public var isEmpty: Bool {
        Self.isBlank(text) && Self.isBlank(from) && Self.isBlank(subject)
            && headers.allSatisfy { Self.isBlank($0.field) || Self.isBlank($0.value) }
            && since == nil && before == nil && readState == .any && !flaggedOnly && maximumUID == nil
    }

    private static func isBlank(_ value: String?) -> Bool {
        (value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    /// Narrows a filter to messages that can still be changed by `markRead`.
    /// Returns `nil` when the caller explicitly asked for already-read mail.
    public func markReadCandidateCriteria() -> MailSearchCriteria? {
        guard readState != .readOnly else { return nil }
        var criteria = self
        criteria.readState = .unreadOnly
        return criteria
    }
}

/// One page of mailbox-search results.
public struct MailSearchResult: Sendable, Equatable {
    /// This page of messages, newest first.
    public var messages: [MailMessage]
    /// Total number of messages the search matched across all pages.
    public var totalMatches: Int
    /// The offset into the full match set this page started at.
    public var offset: Int
    /// Whether more results exist beyond this page.
    public var hasMore: Bool

    public init(messages: [MailMessage], totalMatches: Int, offset: Int, hasMore: Bool) {
        self.messages = messages
        self.totalMatches = totalMatches
        self.offset = offset
        self.hasMore = hasMore
    }

    /// An empty result (no matches), used when a search returns nothing or the
    /// requested page is beyond the match set.
    public static func empty(offset: Int) -> MailSearchResult {
        MailSearchResult(messages: [], totalMatches: 0, offset: offset, hasMore: false)
    }
}
