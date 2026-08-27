import XCTest
@testable import Sentwise

/// A fake log reader returning injected entries, so the diagnostics flow can be
/// tested without touching the real `OSLogStore`.
private final class StubDiagnosticsLogReader: DiagnosticsLogReading {
    let entries: [DiagnosticsLogEntry]
    let error: Error?
    private(set) var lastIncludingVerbose: Bool?
    private(set) var lastSince: Date?

    init(entries: [DiagnosticsLogEntry], error: Error? = nil) {
        self.entries = entries
        self.error = error
    }

    func recentEntries(since date: Date, includingVerbose: Bool) throws -> [DiagnosticsLogEntry] {
        lastSince = date
        lastIncludingVerbose = includingVerbose
        if let error { throw error }
        return entries
    }
}

private enum StubDiagnosticsError: LocalizedError {
    case logStoreUnavailable

    var errorDescription: String? {
        "OSLogStore unavailable at /Users/priya/Library/Logs token=abc123"
    }
}

/// A fake action router that records reveal/open calls instead of launching
/// Finder or Mail.
private final class RecordingDiagnosticsActionRouter: DiagnosticsActionRouting, @unchecked Sendable {
    private(set) var revealed: [URL] = []
    private(set) var opened: [URL] = []

    func revealInFinder(_ url: URL) { revealed.append(url) }
    func open(_ url: URL) { opened.append(url) }
}

@MainActor
final class AppStateDiagnosticsTests: XCTestCase {

    private func makeAppState(
        persistence: AppStateMemoryPersistence,
        secrets: SecretStore = InMemorySecretStore()
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testReportAProblemWritesRedactedBundleAndRoutesFinderAndMail() throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [
            DiagnosticsLogEntry(
                date: Date(timeIntervalSince1970: 1_700_000_000),
                category: "InboxWatcher",
                level: .notice,
                message: "Drafted reply to marcus@acme.example"
            )
        ])
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()

        let url = appState.reportAProblem(
            reader: reader,
            router: router,
            now: Date(timeIntervalSince1970: 1_700_000_100),
            directory: dir,
            isHuntMode: false
        )

        let bundleURL = try XCTUnwrap(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        let contents = try String(contentsOf: bundleURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("marcus@acme.example"), contents)
        XCTAssertTrue(contents.contains(DiagnosticsRedactor.emailPlaceholder))

        XCTAssertEqual(router.revealed, [bundleURL])
        XCTAssertEqual(router.opened.count, 1)
        let opened = try XCTUnwrap(router.opened.first)
        XCTAssertEqual(opened.scheme, "mailto")
        XCTAssertTrue(opened.absoluteString.hasPrefix("mailto:feedback@sentwise.ai"))
    }

    func testReportAProblemPassesVerboseFlagToReader() throws {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            verboseDiagnosticLogging: true
        ))
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [])
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()

        appState.reportAProblem(reader: reader, router: router, directory: dir, isHuntMode: false)

        XCTAssertEqual(reader.lastIncludingVerbose, true)
    }

    func testReportAProblemWritesCollectionFailureIntoBundle() throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [], error: StubDiagnosticsError.logStoreUnavailable)
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()

        let url = appState.reportAProblem(
            reader: reader,
            router: router,
            directory: dir,
            isHuntMode: false
        )

        let bundleURL = try XCTUnwrap(url)
        let contents = try String(contentsOf: bundleURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("Log collection failed:"))
        XCTAssertFalse(contents.contains("/Users/priya"), contents)
        XCTAssertFalse(contents.contains("abc123"), contents)
        XCTAssertTrue(contents.contains(DiagnosticsRedactor.pathPlaceholder))
        XCTAssertTrue(contents.contains(DiagnosticsRedactor.tokenPlaceholder))
        XCTAssertEqual(router.revealed, [bundleURL])
        XCTAssertEqual(router.opened.count, 1)
    }

    func testReportAProblemFallsBackToTemporaryDirectoryWhenPrimaryWriteFails() throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [])
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()
        let blockedDirectory = dir.appendingPathComponent("not-a-directory")
        let fallbackDirectory = dir.appendingPathComponent("fallback")
        try "occupied".write(to: blockedDirectory, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)

        let url = appState.reportAProblem(
            reader: reader,
            router: router,
            directory: blockedDirectory,
            fallbackDirectory: fallbackDirectory,
            isHuntMode: false
        )

        let bundleURL = try XCTUnwrap(url)
        XCTAssertEqual(
            bundleURL.deletingLastPathComponent().standardizedFileURL.path,
            fallbackDirectory.standardizedFileURL.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertEqual(router.revealed, [bundleURL])
        XCTAssertEqual(router.opened.count, 1)
    }

    func testReportAProblemDoesNotOpenMailWhenBundleWriteFails() throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [])
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()
        let blockedDirectory = dir.appendingPathComponent("not-a-directory")
        let blockedFallback = dir.appendingPathComponent("not-a-fallback-directory")
        try "occupied".write(to: blockedDirectory, atomically: true, encoding: .utf8)
        try "occupied".write(to: blockedFallback, atomically: true, encoding: .utf8)

        let url = appState.reportAProblem(
            reader: reader,
            router: router,
            directory: blockedDirectory,
            fallbackDirectory: blockedFallback,
            isHuntMode: false
        )

        XCTAssertNil(url)
        XCTAssertTrue(router.revealed.isEmpty)
        XCTAssertTrue(router.opened.isEmpty)
    }

    func testReportAProblemSuppressesSideEffectsInHuntMode() throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [])
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()

        let url = appState.reportAProblem(
            reader: reader,
            router: router,
            directory: dir,
            isHuntMode: true
        )

        // The bundle is still written, but Finder/Mail are never touched.
        XCTAssertNotNil(url)
        XCTAssertTrue(router.revealed.isEmpty)
        XCTAssertTrue(router.opened.isEmpty)
    }

    func testDiagnosticsContextCarriesNoAccountEmail() async {
        let persistence = AppStateMemoryPersistence()
        let secrets = InMemorySecretStore()
        let appState = makeAppState(persistence: persistence, secrets: secrets)
        await connect(appState, email: "private.person@gmail.com", host: "imap.gmail.com", password: "pw")

        let rendered = appState.makeDiagnosticsContext().render()
        XCTAssertFalse(rendered.contains("private.person@gmail.com"), rendered)
        XCTAssertFalse(rendered.contains("@"), rendered)
        XCTAssertTrue(rendered.contains("LLM provider:"))
    }

    func testVerboseLoggingTogglePersistsAndRoundTrips() async throws {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com"
        ))
        let appState = makeAppState(persistence: persistence)
        XCTAssertFalse(appState.verboseDiagnosticLogging)

        appState.verboseDiagnosticLogging = true
        try await Task.sleep(nanoseconds: 650_000_000)

        XCTAssertTrue(persistence.loadSettings().verboseDiagnosticLogging)
        XCTAssertTrue(DiagnosticLog.isVerbose)
    }

    // MARK: - Helpers

    private func connect(_ appState: AppState, email: String, host: String, password: String) async {
        appState.mailEmail = email
        appState.mailHost = host
        appState.mailPort = 993
        appState.mailAppPassword = password
        await appState.testConnection()
    }
}
