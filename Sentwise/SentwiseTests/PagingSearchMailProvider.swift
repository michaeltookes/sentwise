import SentwiseMail
import Foundation

/// A mail provider that models server-side search over a fixed message list,
/// paging by `(offset, limit)` — for exercising the mailbox browser (item 40).
/// Kept in its own file so `AppStateTestDoubles` stays within the length limit.
final class PagingSearchMailProvider: MailProvider, @unchecked Sendable {
    var allMessages: [MailMessage]
    var searchError: MailError?
    private(set) var searchCallCount = 0
    private(set) var lastCriteria: MailSearchCriteria?
    private(set) var lastMailbox: Mailbox?
    private(set) var lastOffset: Int?
    private(set) var lastLimit: Int?
    private(set) var lastSnapshotMessageCount: Int?
    /// The credentials the most recent search/page fetch ran under, so tests can
    /// assert which account the browser reached (item 103).
    private(set) var lastCredentials: MailAccountCredentials?

    init(allMessages: [MailMessage]) {
        self.allMessages = allMessages
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        []
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        Data()
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {}

    func searchMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        offset: Int,
        limit: Int
    ) async throws -> MailSearchResult {
        searchCallCount += 1
        lastCriteria = criteria
        lastMailbox = mailbox
        lastOffset = offset
        lastLimit = limit
        lastCredentials = credentials
        if let searchError { throw searchError }

        let matchingMessages = allMessages.filter { message in
            criteria.maximumUID.map { message.id <= $0 } ?? true
        }
        let total = matchingMessages.count
        guard offset < total, limit > 0 else {
            return MailSearchResult(messages: [], totalMatches: total, offset: offset, hasMore: false)
        }
        let end = min(offset + limit, total)
        return MailSearchResult(
            messages: Array(matchingMessages[offset..<end]),
            totalMatches: total,
            offset: offset,
            hasMore: end < total
        )
    }

    func fetchMessagePage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        offset: Int,
        limit: Int,
        snapshotMessageCount: Int?
    ) async throws -> MailSearchResult {
        searchCallCount += 1
        lastCriteria = MailSearchCriteria()
        lastMailbox = mailbox
        lastOffset = offset
        lastLimit = limit
        lastSnapshotMessageCount = snapshotMessageCount
        lastCredentials = credentials
        if let searchError { throw searchError }

        let currentTotal = allMessages.count
        let pageTotal = snapshotMessageCount ?? currentTotal
        guard pageTotal > 0, limit > 0, offset >= 0, offset < pageTotal else {
            return MailSearchResult(messages: [], totalMatches: pageTotal, offset: offset, hasMore: false)
        }

        let upperSequence = pageTotal - offset
        let lowerSequence = max(1, upperSequence - limit + 1)
        let clampedUpperSequence = min(upperSequence, currentTotal)
        guard lowerSequence <= clampedUpperSequence else {
            return MailSearchResult(
                messages: [],
                totalMatches: pageTotal,
                offset: offset,
                hasMore: offset + limit < pageTotal
            )
        }

        let startIndex = currentTotal - clampedUpperSequence
        let endIndex = currentTotal - lowerSequence + 1
        return MailSearchResult(
            messages: Array(allMessages[startIndex..<endIndex]),
            totalMatches: pageTotal,
            offset: offset,
            hasMore: offset + limit < pageTotal
        )
    }
}
