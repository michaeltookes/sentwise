import XCTest
@testable import Sentwise

/// Unit tests for `DiagnosticsReportBuilder` and `DiagnosticsContext` — bundle
/// assembly, redaction of captured log lines, and PII-safety (item 36).
final class DiagnosticsReportBuilderTests: XCTestCase {

    private func sampleContext() -> DiagnosticsContext {
        DiagnosticsContext(
            appVersion: "1.4.2",
            buildNumber: "88",
            osVersion: "14.5.0",
            hardwareModel: "Mac15,3",
            providerKind: "managed",
            sendBehavior: "saveAsDraft",
            pollIntervalSeconds: 300,
            notificationPermission: "authorized",
            verboseLogging: false,
            watchedFolderEnabled: false
        )
    }

    func testContextRenderContainsVersionAndProviderKind() {
        let rendered = sampleContext().render()
        XCTAssertTrue(rendered.contains("App version: 1.4.2 (88)"))
        XCTAssertTrue(rendered.contains("macOS: 14.5.0"))
        XCTAssertTrue(rendered.contains("LLM provider: managed"))
        XCTAssertTrue(rendered.contains("Poll interval: 300s"))
    }

    func testReportRedactsEmailAddressesInLogLines() {
        let entries = [
            DiagnosticsLogEntry(
                date: Date(timeIntervalSince1970: 1_700_000_000),
                category: "InboxWatcher",
                level: .notice,
                message: "Drafted reply to marcus@acme.example"
            )
        ]
        let report = DiagnosticsReportBuilder.build(context: sampleContext(), entries: entries)
        XCTAssertFalse(report.contains("marcus@acme.example"), report)
        XCTAssertTrue(report.contains(DiagnosticsRedactor.emailPlaceholder))
    }

    func testReportKeepsVersionAndContextIntact() {
        let report = DiagnosticsReportBuilder.build(context: sampleContext(), entries: [])
        XCTAssertTrue(report.contains("App version: 1.4.2 (88)"))
        XCTAssertTrue(report.contains("macOS: 14.5.0"))
        XCTAssertTrue(report.contains("--- Environment ---"))
        XCTAssertTrue(report.contains("(no recent log entries)"))
    }

    func testBundleContainsNoAccountEmailEvenIfContextIsPolluted() {
        // Defence in depth: even if an email somehow reached a context field, the
        // whole assembled report is redacted, so nothing leaks.
        var context = sampleContext()
        context = DiagnosticsContext(
            appVersion: context.appVersion,
            buildNumber: context.buildNumber,
            osVersion: context.osVersion,
            hardwareModel: context.hardwareModel,
            providerKind: "managed (signed in as sam@private.example)",
            sendBehavior: context.sendBehavior,
            pollIntervalSeconds: context.pollIntervalSeconds,
            notificationPermission: context.notificationPermission,
            verboseLogging: context.verboseLogging,
            watchedFolderEnabled: context.watchedFolderEnabled
        )
        let report = DiagnosticsReportBuilder.build(context: context, entries: [])
        XCTAssertFalse(report.contains("sam@private.example"), report)
        XCTAssertFalse(report.contains("@private"), report)
    }

    func testReportHeaderStatesItIsRedacted() {
        let report = DiagnosticsReportBuilder.build(context: sampleContext(), entries: [])
        XCTAssertTrue(report.contains("redacted"))
        XCTAssertTrue(report.contains("no message bodies"))
    }
}
