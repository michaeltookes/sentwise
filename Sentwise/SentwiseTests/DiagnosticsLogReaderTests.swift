import XCTest
@testable import Sentwise

/// Unit tests for the log-reader configuration that can be validated without
/// opening the real unified log store.
final class DiagnosticsLogReaderTests: XCTestCase {

    func testReaderDefaultsToSystemScopeForPriorLaunchCollection() {
        let reader = OSLogStoreDiagnosticsReader()

        XCTAssertEqual(reader.scope, .system)
    }

    func testReaderDefaultsToBoundedCollectionLimits() {
        let reader = OSLogStoreDiagnosticsReader()

        XCTAssertEqual(reader.maxEntries, OSLogStoreDiagnosticsReader.defaultMaxEntries)
        XCTAssertEqual(reader.maxMessageBytes, OSLogStoreDiagnosticsReader.defaultMaxMessageBytes)
    }

    func testReaderReturnsNoEntriesWhenCollectionBoundsAreZero() throws {
        let noEntries = OSLogStoreDiagnosticsReader(maxEntries: 0)
        let noBytes = OSLogStoreDiagnosticsReader(maxMessageBytes: 0)

        XCTAssertEqual(try noEntries.recentEntries(since: .distantPast, includingVerbose: true), [])
        XCTAssertEqual(try noBytes.recentEntries(since: .distantPast, includingVerbose: true), [])
    }

    func testTailBufferRetainsNewestEntriesWhenEntryLimitIsExceeded() {
        var buffer = DiagnosticsLogTailBuffer(maxEntries: 3, maxMessageBytes: 1_000)

        ["oldest", "older", "middle", "newer", "newest"].forEach {
            buffer.append(entry(message: $0))
        }

        XCTAssertEqual(buffer.entries.map(\.message), ["middle", "newer", "newest"])
    }

    func testTailBufferRetainsNewestEntriesWhenByteLimitIsExceeded() {
        var buffer = DiagnosticsLogTailBuffer(maxEntries: 10, maxMessageBytes: 14)

        ["oldest", "middle", "newest"].forEach {
            buffer.append(entry(message: $0))
        }

        XCTAssertEqual(buffer.entries.map(\.message), ["middle", "newest"])
    }

    func testTailBufferSkipsSingleEntriesLargerThanByteLimit() {
        var buffer = DiagnosticsLogTailBuffer(maxEntries: 10, maxMessageBytes: 8)

        buffer.append(entry(message: "too-large-entry"))
        buffer.append(entry(message: "new"))

        XCTAssertEqual(buffer.entries.map(\.message), ["new"])
    }

    func testSubsystemPredicateOnlyMatchesConfiguredSubsystem() {
        let predicate = OSLogStoreDiagnosticsReader.makePredicate(
            subsystem: "com.example.Sentwise"
        )

        XCTAssertTrue(predicate.evaluate(with: ["subsystem": "com.example.Sentwise"]))
        XCTAssertFalse(predicate.evaluate(with: ["subsystem": "com.example.Other"]))
    }

    private func entry(message: String) -> DiagnosticsLogEntry {
        DiagnosticsLogEntry(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            category: "Diagnostics",
            level: .notice,
            message: message
        )
    }
}
