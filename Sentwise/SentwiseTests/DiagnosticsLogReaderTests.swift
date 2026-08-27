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

    func testSubsystemPredicateOnlyMatchesConfiguredSubsystem() {
        let predicate = OSLogStoreDiagnosticsReader.makePredicate(
            subsystem: "com.example.Sentwise"
        )

        XCTAssertTrue(predicate.evaluate(with: ["subsystem": "com.example.Sentwise"]))
        XCTAssertFalse(predicate.evaluate(with: ["subsystem": "com.example.Other"]))
    }
}
