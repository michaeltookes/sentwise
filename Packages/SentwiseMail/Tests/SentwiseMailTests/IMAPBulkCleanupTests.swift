import Foundation
import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import SentwiseMail

// swiftlint:disable file_length type_body_length
/// Drives `IMAPBulkCleanupHandler` through the real IMAP decoder with an
/// `EmbeddedChannel` (item 42). Covers the windowed selection walk, the preview
/// path, and the batched mark-read / move paths — including the safety
/// properties: selection completes before any mutation, and nothing outside the
/// filter is ever touched.
final class IMAPBulkCleanupTests: XCTestCase {

    private func makeChannel(
        criteria: MailSearchCriteria = MailSearchCriteria(),
        action: MailBulkAction? = nil,
        sampleLimit: Int = 25,
        selectionCap: Int = 5_000,
        selection: MailBulkSelection? = nil,
        mailbox: String = "INBOX",
        destination: String? = nil,
        onProgress: (@Sendable (MailBulkProgress) -> Void)? = nil
    ) throws -> (EmbeddedChannel, EventLoopFuture<IMAPBulkOutcome>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: IMAPBulkOutcome.self)
        let handler = IMAPBulkCleanupHandler(
            email: "me@example.com",
            password: "pw",
            mailboxName: mailbox,
            destinationName: destination,
            request: IMAPBulkCleanupRequest(
                mailbox: .inbox,
                criteria: criteria,
                action: action,
                selection: selection,
                sampleLimit: sampleLimit,
                selectionCap: selectionCap,
                onProgress: onProgress
            ),
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([IMAPClientHandler(), handler])
        return (channel, promise.futureResult)
    }

    @discardableResult
    private func feed(_ channel: EmbeddedChannel, _ response: String) throws -> String {
        try channel.writeInbound(ByteBuffer(string: response))
        var out = ""
        while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
            out += String(buffer: buffer)
        }
        return out
    }

    /// Drives greeting → login → select with `exists` messages in the mailbox,
    /// returning the outbound the SELECT's OK triggered (the first SEARCH).
    @discardableResult
    private func advanceThroughSelect(_ channel: EmbeddedChannel, exists: Int) throws -> String {
        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* \(exists) EXISTS\r\n")
        try feed(channel, "* OK [UIDVALIDITY 123456] UIDs valid\r\n")
        return try feed(channel, "A2 OK [READ-WRITE] SELECT completed\r\n")
    }

    private func envelope(uid: UInt32, seq: UInt32, subject: String, from: String) -> String {
        "* \(seq) FETCH (UID \(uid) ENVELOPE (\"Wed, 1 Jan 2026 10:00:00 +0000\" "
            + "\"\(subject)\" ((\"Sender\" NIL \"\(from)\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n"
    }

    @discardableResult
    private func feedSearch(
        _ channel: EmbeddedChannel,
        windowIndex: Int,
        sequenceNumbers: [UInt32]
    ) throws -> String {
        let ids = sequenceNumbers.map(String.init).joined(separator: " ")
        let response = ids.isEmpty ? "* SEARCH\r\n" : "* SEARCH \(ids)\r\n"
        try feed(channel, response)
        return try feed(channel, "S\(windowIndex) OK SEARCH completed\r\n")
    }

    @discardableResult
    private func feedUIDResolution(
        _ channel: EmbeddedChannel,
        windowIndex: Int,
        mappings: [(sequence: UInt32, uid: UInt32)]
    ) throws -> String {
        for mapping in mappings {
            try feed(channel, "* \(mapping.sequence) FETCH (UID \(mapping.uid))\r\n")
        }
        return try feed(channel, "F\(windowIndex) OK FETCH completed\r\n")
    }

    @discardableResult
    private func feedUIDValidation(
        _ channel: EmbeddedChannel,
        batchIndex: Int = 0,
        uids: [UInt32]
    ) throws -> String {
        let ids = uids.map(String.init).joined(separator: " ")
        let response = ids.isEmpty ? "* SEARCH\r\n" : "* SEARCH \(ids)\r\n"
        try feed(channel, response)
        return try feed(channel, "V\(batchIndex) OK SEARCH completed\r\n")
    }

    @discardableResult
    private func resolveWindow(
        _ channel: EmbeddedChannel,
        windowIndex: Int,
        mappings: [(sequence: UInt32, uid: UInt32)]
    ) throws -> String {
        try feedSearch(channel, windowIndex: windowIndex, sequenceNumbers: mappings.map { $0.sequence })
        return try feedUIDResolution(channel, windowIndex: windowIndex, mappings: mappings)
    }

    // MARK: - Windowed selection

    func testSearchIsBoundedToASequenceWindowRatherThanAUIDWindow() throws {
        let (channel, _) = try makeChannel()
        let search = try advanceThroughSelect(channel, exists: 1200)

        // Newest window first, and bounded — never an unqualified "SEARCH ALL",
        // which is what overflows the frame cap on a huge mailbox (item 45).
        XCTAssertTrue(search.contains("SEARCH"), search)
        XCTAssertFalse(search.contains("UID SEARCH"), search)
        XCTAssertTrue(search.contains("701:1200"), search)
        XCTAssertFalse(search.contains(" 1:1200"), search)
    }

    func testSelectionWalksEveryWindowUntilExhausted() throws {
        let (channel, future) = try makeChannel()
        try advanceThroughSelect(channel, exists: 1200)

        let firstResolve = try feedSearch(channel, windowIndex: 0, sequenceNumbers: [900])
        XCTAssertTrue(firstResolve.contains("FETCH"), firstResolve)
        let second = try feedUIDResolution(channel, windowIndex: 0, mappings: [(sequence: 900, uid: 1900)])
        XCTAssertTrue(second.contains("201:700"), second)

        try feedSearch(channel, windowIndex: 1, sequenceNumbers: [300])
        let third = try feedUIDResolution(channel, windowIndex: 1, mappings: [(sequence: 300, uid: 1300)])
        XCTAssertTrue(third.contains("1:200"), third)

        try resolveWindow(channel, windowIndex: 2, mappings: [(sequence: 100, uid: 1100)])

        // All three windows contributed; preview then samples them.
        try feed(channel, envelope(uid: 1900, seq: 900, subject: "c", from: "c"))
        try feed(channel, envelope(uid: 1300, seq: 300, subject: "b", from: "b"))
        try feed(channel, envelope(uid: 1100, seq: 100, subject: "a", from: "a"))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let outcome = try future.wait()
        XCTAssertEqual(outcome.matchCount, 3)
        XCTAssertFalse(outcome.isPartial)
    }

    func testEmptyMailboxNeedsNoSearchAndPreviewsNothing() throws {
        let (channel, future) = try makeChannel()
        let out = try advanceThroughSelect(channel, exists: 0)

        XCTAssertFalse(out.contains("SEARCH"), out)
        let outcome = try future.wait()
        XCTAssertEqual(outcome.matchCount, 0)
        XCTAssertTrue(outcome.sample.isEmpty)
        XCTAssertFalse(outcome.isPartial)
    }

    func testCriteriaAreAndedWithTheWindow() throws {
        let (channel, _) = try makeChannel(criteria: MailSearchCriteria(from: "spam@junk.com", readState: .unreadOnly))
        let search = try advanceThroughSelect(channel, exists: 10)

        XCTAssertFalse(search.contains("UID SEARCH"), search)
        XCTAssertTrue(search.contains("1:10"), search)
        XCTAssertTrue(search.contains("FROM"), search)
        XCTAssertTrue(search.contains("spam@junk.com"), search)
        XCTAssertTrue(search.contains("UNSEEN"), search)
    }

    // MARK: - Preview

    func testPreviewSamplesNewestMatchesAndChangesNothing() throws {
        let (channel, future) = try makeChannel()
        try advanceThroughSelect(channel, exists: 5)

        let resolve = try feedSearch(channel, windowIndex: 0, sequenceNumbers: [1, 2, 3])
        XCTAssertTrue(resolve.contains("FETCH"), resolve)
        XCTAssertFalse(resolve.contains("UID FETCH"), resolve)
        let afterResolve = try feedUIDResolution(
            channel,
            windowIndex: 0,
            mappings: [(sequence: 1, uid: 11), (sequence: 2, uid: 12), (sequence: 3, uid: 13)]
        )

        // A preview must only ever read — never STORE or MOVE.
        XCTAssertTrue(afterResolve.contains("UID FETCH"), afterResolve)
        XCTAssertFalse(afterResolve.contains("STORE"), afterResolve)
        XCTAssertFalse(afterResolve.contains("MOVE"), afterResolve)

        try feed(channel, envelope(uid: 13, seq: 3, subject: "newest", from: "a@b.com"))
        try feed(channel, envelope(uid: 12, seq: 2, subject: "middle", from: "a@b.com"))
        try feed(channel, envelope(uid: 11, seq: 1, subject: "oldest", from: "a@b.com"))
        try feed(channel, "A3 OK FETCH completed\r\n")

        let outcome = try future.wait()
        XCTAssertEqual(outcome.matchCount, 3)
        XCTAssertEqual(outcome.sample.map(\.id), [13, 12, 11])
        XCTAssertEqual(outcome.selection, MailBulkSelection(uidValidity: 123456, uids: [13, 12, 11]))
        XCTAssertEqual(outcome.affectedCount, 0)
    }

    func testPreviewSampleIsCappedButMatchCountIsNot() throws {
        let (channel, _) = try makeChannel(sampleLimit: 2)
        try advanceThroughSelect(channel, exists: 5)

        let fetch = try resolveWindow(
            channel,
            windowIndex: 0,
            mappings: [
                (sequence: 1, uid: 11),
                (sequence: 2, uid: 12),
                (sequence: 3, uid: 13),
                (sequence: 4, uid: 14)
            ]
        )

        // Only the two newest UIDs are fetched for display.
        XCTAssertTrue(fetch.contains("14"), fetch)
        XCTAssertTrue(fetch.contains("13"), fetch)
        XCTAssertFalse(fetch.contains("11"), fetch)
    }

    func testSelectionCapMarksResultPartial() throws {
        let (channel, future) = try makeChannel(sampleLimit: 0, selectionCap: 2)
        try advanceThroughSelect(channel, exists: 5)

        try resolveWindow(
            channel,
            windowIndex: 0,
            mappings: [
                (sequence: 1, uid: 11),
                (sequence: 2, uid: 12),
                (sequence: 3, uid: 13),
                (sequence: 4, uid: 14)
            ]
        )

        let outcome = try future.wait()
        XCTAssertEqual(outcome.matchCount, 2, "must not select beyond the cap")
        XCTAssertTrue(outcome.isPartial, "the user must be told this is a lower bound")
    }

    func testExactSelectionCapAfterFinalWindowIsNotPartial() throws {
        let (channel, future) = try makeChannel(sampleLimit: 0, selectionCap: 2)
        try advanceThroughSelect(channel, exists: 2)

        try resolveWindow(
            channel,
            windowIndex: 0,
            mappings: [(sequence: 1, uid: 11), (sequence: 2, uid: 12)]
        )

        let outcome = try future.wait()
        XCTAssertEqual(outcome.matchCount, 2)
        XCTAssertFalse(outcome.isPartial)
    }

    func testUIDResolutionIgnoresFetchesOutsideTheActiveSearchWindow() throws {
        let (channel, future) = try makeChannel(sampleLimit: 0)
        try advanceThroughSelect(channel, exists: 5)

        try feedSearch(channel, windowIndex: 0, sequenceNumbers: [1])
        try feed(channel, "* 2 FETCH (UID 99)\r\n")
        try feedUIDResolution(channel, windowIndex: 0, mappings: [(sequence: 1, uid: 11)])

        let outcome = try future.wait()
        XCTAssertEqual(outcome.matchCount, 1)
    }

    func testExpungeDuringSearchRequiresFreshPreview() throws {
        let (channel, future) = try makeChannel(sampleLimit: 0)
        try advanceThroughSelect(channel, exists: 5)

        try feed(channel, "* 2 EXPUNGE\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .commandFailed(let detail) = error as? MailError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("mailbox changed"), detail)
        }
        _ = try? channel.finish()
    }

    func testExpungeDuringUIDResolutionRequiresFreshPreview() throws {
        let (channel, future) = try makeChannel(sampleLimit: 0)
        try advanceThroughSelect(channel, exists: 5)
        let resolve = try feedSearch(channel, windowIndex: 0, sequenceNumbers: [1])
        XCTAssertTrue(resolve.contains("FETCH"), resolve)

        try feed(channel, "* 1 EXPUNGE\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .commandFailed(let detail) = error as? MailError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("mailbox changed"), detail)
        }
        _ = try? channel.finish()
    }

    // MARK: - Mark read

    func testMarkReadStoresSeenFlagOverMatchesOnly() throws {
        let (channel, future) = try makeChannel(action: .markRead)
        try advanceThroughSelect(channel, exists: 5)

        let validation = try resolveWindow(
            channel,
            windowIndex: 0,
            mappings: [(sequence: 1, uid: 11), (sequence: 2, uid: 12)]
        )
        XCTAssertTrue(validation.contains("UID SEARCH"), validation)
        let store = try feedUIDValidation(channel, uids: [11, 12])

        XCTAssertTrue(store.contains("UID STORE"), store)
        XCTAssertTrue(store.contains("\\Seen"), store)
        XCTAssertTrue(store.contains("11"), store)
        XCTAssertTrue(store.contains("12"), store)
        XCTAssertFalse(store.contains("MOVE"), store)

        try feed(channel, "B0 OK STORE completed\r\n")
        let outcome = try future.wait()
        XCTAssertEqual(outcome.affectedCount, 2)
    }

    func testLiveMarkReadSelectionOnlySearchesUnreadMatches() throws {
        let (channel, _) = try makeChannel(action: .markRead)
        let search = try advanceThroughSelect(channel, exists: 5)

        XCTAssertTrue(search.contains("SEARCH"), search)
        XCTAssertTrue(search.contains("UNSEEN"), search)
        XCTAssertFalse(search.contains(" SEEN"), search)
    }

    func testLiveMarkReadReadOnlyFilterAppliesNothing() throws {
        let (channel, future) = try makeChannel(
            criteria: MailSearchCriteria(readState: .readOnly),
            action: .markRead
        )
        let out = try advanceThroughSelect(channel, exists: 5)

        XCTAssertFalse(out.contains("SEARCH"), out)
        XCTAssertFalse(out.contains("STORE"), out)
        let outcome = try future.wait()
        XCTAssertEqual(outcome.affectedCount, 0)
    }

    func testApplyWithPreviewSelectionRevalidatesUIDsAndSkipsLiveSearch() throws {
        let selection = MailBulkSelection(uidValidity: 123456, uids: [22, 21])
        let (channel, future) = try makeChannel(action: .markRead, selection: selection)
        let out = try advanceThroughSelect(channel, exists: 5)

        XCTAssertTrue(out.contains("UID SEARCH"), out)
        XCTAssertFalse(out.contains("UID STORE"), out)
        XCTAssertTrue(out.contains("22"), out)
        XCTAssertTrue(out.contains("21"), out)

        let store = try feedUIDValidation(channel, uids: [22, 21])
        XCTAssertTrue(store.contains("UID STORE"), store)
        try feed(channel, "B0 OK STORE completed\r\n")
        XCTAssertEqual(try future.wait().affectedCount, 2)
    }

    func testApplyWithPreviewSelectionDropsMissingUIDsBeforeCounting() throws {
        let selection = MailBulkSelection(uidValidity: 123456, uids: [22, 21, 20])
        let (channel, future) = try makeChannel(action: .markRead, selection: selection)
        try advanceThroughSelect(channel, exists: 5)

        let store = try feedUIDValidation(channel, uids: [22, 20])

        XCTAssertTrue(store.contains("UID STORE"), store)
        XCTAssertTrue(store.contains("22"), store)
        XCTAssertTrue(store.contains("20"), store)
        XCTAssertFalse(store.contains("21"), store)

        try feed(channel, "B0 OK STORE completed\r\n")
        XCTAssertEqual(try future.wait().affectedCount, 2)
    }

    func testApplyWithPreviewSelectionHonorsSelectionCap() throws {
        let selection = MailBulkSelection(uidValidity: 123456, uids: [25, 24, 23])
        let (channel, future) = try makeChannel(
            action: .markRead,
            selectionCap: 2,
            selection: selection
        )
        let validation = try advanceThroughSelect(channel, exists: 5)

        XCTAssertTrue(validation.contains("UID SEARCH"), validation)
        XCTAssertTrue(validation.contains("25"), validation)
        XCTAssertTrue(validation.contains("24"), validation)
        XCTAssertFalse(validation.contains("23"), validation)

        let store = try feedUIDValidation(channel, uids: [25, 24])
        XCTAssertTrue(store.contains("UID STORE"), store)
        XCTAssertTrue(store.contains("25"), store)
        XCTAssertTrue(store.contains("24"), store)
        XCTAssertFalse(store.contains("23"), store)

        try feed(channel, "B0 OK STORE completed\r\n")
        let outcome = try future.wait()
        XCTAssertEqual(outcome.matchCount, 2)
        XCTAssertEqual(outcome.affectedCount, 2)
        XCTAssertTrue(outcome.isPartial)
    }

    func testExpungeDuringUIDValidationDropsMissingUIDsBeforeCounting() throws {
        let recorder = ProgressRecorder()
        let selection = MailBulkSelection(uidValidity: 123456, uids: [22, 21])
        let (channel, future) = try makeChannel(
            action: .markRead,
            selection: selection,
            onProgress: { recorder.append($0) }
        )
        let validation = try advanceThroughSelect(channel, exists: 5)
        XCTAssertTrue(validation.contains("UID SEARCH"), validation)

        try feed(channel, "* 1 EXPUNGE\r\n")
        let store = try feedUIDValidation(channel, uids: [22])

        XCTAssertTrue(store.contains("UID STORE"), store)
        XCTAssertTrue(store.contains("22"), store)
        XCTAssertFalse(store.contains("21"), store)

        try feed(channel, "B0 OK STORE completed\r\n")
        XCTAssertEqual(try future.wait().affectedCount, 1)
        XCTAssertEqual(recorder.values, [MailBulkProgress(processed: 1, total: 1)])
    }

    func testApplyWithStalePreviewSelectionRequiresFreshPreview() throws {
        let selection = MailBulkSelection(uidValidity: 999, uids: [22])
        let (channel, future) = try makeChannel(action: .markRead, selection: selection)
        let out = try advanceThroughSelect(channel, exists: 5)

        XCTAssertFalse(out.contains("UID STORE"), out)
        XCTAssertThrowsError(try future.wait()) { error in
            guard case .commandFailed(let detail) = error as? MailError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("Preview again"), detail)
        }
        _ = try? channel.finish()
    }

    func testNoMatchesAppliesNothing() throws {
        let (channel, future) = try makeChannel(action: .markRead)
        try advanceThroughSelect(channel, exists: 5)

        let after = try feedSearch(channel, windowIndex: 0, sequenceNumbers: [])

        XCTAssertFalse(after.contains("UID STORE"), after)
        let outcome = try future.wait()
        XCTAssertEqual(outcome.affectedCount, 0)
    }

    // MARK: - Move

    func testMoveToTrashTargetsTheConfiguredFolder() throws {
        let (channel, future) = try makeChannel(action: .moveToTrash, destination: "Trash")
        try advanceThroughSelect(channel, exists: 5)

        try resolveWindow(
            channel,
            windowIndex: 0,
            mappings: [(sequence: 1, uid: 11), (sequence: 2, uid: 12)]
        )
        let move = try feedUIDValidation(channel, uids: [11, 12])

        XCTAssertTrue(move.contains("UID MOVE"), move)
        XCTAssertTrue(move.contains("Trash"), move)

        try feed(channel, "B0 OK MOVE completed\r\n")
        XCTAssertEqual(try future.wait().affectedCount, 2)
    }

    func testArchiveUsesProviderArchiveFolder() throws {
        let (channel, future) = try makeChannel(action: .archive, destination: "[Gmail]/All Mail")
        try advanceThroughSelect(channel, exists: 5)

        try resolveWindow(
            channel,
            windowIndex: 0,
            mappings: [(sequence: 1, uid: 11)]
        )
        let move = try feedUIDValidation(channel, uids: [11])

        XCTAssertTrue(move.contains("UID MOVE"), move)
        XCTAssertTrue(move.contains("All Mail"), move)

        try feed(channel, "B0 OK MOVE completed\r\n")
        XCTAssertEqual(try future.wait().affectedCount, 1)
    }

    /// The ordering that makes bulk moves safe: every window is scanned before
    /// the first MOVE, because a MOVE renumbers the sequence space the scan is
    /// still walking.
    func testSelectionCompletesBeforeAnyMutation() throws {
        let (channel, _) = try makeChannel(action: .moveToTrash, destination: "Trash")
        try advanceThroughSelect(channel, exists: 1200)

        let afterFirstWindow = try feedSearch(channel, windowIndex: 0, sequenceNumbers: [900])
        XCTAssertFalse(
            afterFirstWindow.contains("MOVE"),
            "moved mail before finishing the scan — later windows would be misnumbered"
        )
        XCTAssertTrue(afterFirstWindow.contains("FETCH"), afterFirstWindow)

        let afterFirstResolve = try feedUIDResolution(
            channel,
            windowIndex: 0,
            mappings: [(sequence: 900, uid: 1900)]
        )
        XCTAssertFalse(
            afterFirstResolve.contains("MOVE"),
            "moved mail before finishing the scan — later windows would be misnumbered"
        )
        XCTAssertTrue(afterFirstResolve.contains("SEARCH"), afterFirstResolve)
    }

    // MARK: - Progress

    func testProgressIsReportedPerBatch() throws {
        let recorder = ProgressRecorder()
        let (channel, future) = try makeChannel(
            action: .markRead,
            onProgress: { recorder.append($0) }
        )
        try advanceThroughSelect(channel, exists: 5)

        try resolveWindow(
            channel,
            windowIndex: 0,
            mappings: [
                (sequence: 1, uid: 11),
                (sequence: 2, uid: 12),
                (sequence: 3, uid: 13)
            ]
        )
        try feedUIDValidation(channel, uids: [11, 12, 13])
        try feed(channel, "B0 OK STORE completed\r\n")

        XCTAssertEqual(try future.wait().affectedCount, 3)
        XCTAssertEqual(recorder.values, [MailBulkProgress(processed: 3, total: 3)])
    }

    // MARK: - Failures

    func testLoginFailureSurfacesAuthenticationError() throws {
        let (channel, future) = try makeChannel()
        try feed(channel, "* OK Service Ready\r\n")
        try feed(channel, "A1 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .authenticationFailed = error as? MailError else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
        _ = try? channel.finish()
    }

    func testRejectedMoveExplainsMissingServerSupport() throws {
        let (channel, future) = try makeChannel(action: .moveToTrash, destination: "Trash")
        try advanceThroughSelect(channel, exists: 5)
        try resolveWindow(channel, windowIndex: 0, mappings: [(sequence: 1, uid: 11)])
        try feedUIDValidation(channel, uids: [11])
        try feed(channel, "B0 BAD Unknown command\r\n")

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .commandFailed(let detail) = error as? MailError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("may not support"), detail)
        }
        _ = try? channel.finish()
    }

    /// A move action with no destination folder must fail loudly rather than
    /// silently degrading into "mark read" — the user asked to move mail, and
    /// quietly doing something else would misreport what happened.
    func testMoveWithoutDestinationFailsInsteadOfMarkingRead() throws {
        let (channel, future) = try makeChannel(action: .moveToTrash, destination: nil)
        try advanceThroughSelect(channel, exists: 5)
        try resolveWindow(channel, windowIndex: 0, mappings: [(sequence: 1, uid: 11)])
        let after = try feedUIDValidation(channel, uids: [11])

        XCTAssertFalse(after.contains("STORE"), after)
        XCTAssertThrowsError(try future.wait()) { error in
            guard case .commandFailed = error as? MailError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
        }
        _ = try? channel.finish()
    }

    func testDecoderOverflowStillMapsToResultTooLarge() throws {
        let (channel, future) = try makeChannel()
        try advanceThroughSelect(channel, exists: 5)

        channel.pipeline.fireErrorCaught(ByteToMessageDecoderError.PayloadTooLargeError())

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .resultTooLarge = error as? MailError else {
                return XCTFail("expected resultTooLarge, got \(error)")
            }
        }
        _ = try? channel.finish()
    }

    func testDroppedConnectionDoesNotLeaveTheCallerHanging() throws {
        let (channel, future) = try makeChannel()
        try advanceThroughSelect(channel, exists: 5)
        _ = try? channel.finish()

        XCTAssertThrowsError(try future.wait()) { error in
            guard case .connectionFailed = error as? MailError else {
                return XCTFail("expected connectionFailed, got \(error)")
            }
        }
    }

    /// Collects progress callbacks from the event loop for assertions.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MailBulkProgress] = []

        func append(_ progress: MailBulkProgress) {
            lock.lock()
            storage.append(progress)
            lock.unlock()
        }

        var values: [MailBulkProgress] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
// swiftlint:enable file_length type_body_length
