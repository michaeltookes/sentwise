import XCTest
@testable import Sentwise

/// A fake log reader returning injected entries, so the diagnostics flow can be
/// tested without touching the real `OSLogStore`.
private final class StubDiagnosticsLogReader: DiagnosticsLogReading, @unchecked Sendable {
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

private final class ThreadRecordingDiagnosticsLogReader: DiagnosticsLogReading, @unchecked Sendable {
    private let lock = NSLock()
    private var observedMainThread: Bool?

    var wasCalledOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return observedMainThread
    }

    func recentEntries(since date: Date, includingVerbose: Bool) throws -> [DiagnosticsLogEntry] {
        lock.lock()
        observedMainThread = Thread.isMainThread
        lock.unlock()
        return []
    }
}

/// A fake action router that records reveal/open calls instead of launching
/// Finder or Mail.
private final class RecordingDiagnosticsActionRouter: DiagnosticsActionRouting, @unchecked Sendable {
    private(set) var revealed: [URL] = []
    private(set) var opened: [URL] = []
    var openResult = true

    func revealInFinder(_ url: URL) { revealed.append(url) }
    func open(_ url: URL) -> Bool {
        opened.append(url)
        return openResult
    }
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

    func testReportAProblemWritesRedactedBundleAndRoutesFinderAndMail() async throws {
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

        let url = await appState.reportAProblem(
            reader: reader,
            router: router,
            now: Date(timeIntervalSince1970: 1_700_000_100),
            directory: dir,
            isHuntMode: false
        )

        let bundleURL = try XCTUnwrap(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertNil(appState.diagnosticsError)
        let contents = try String(contentsOf: bundleURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("marcus@acme.example"), contents)
        XCTAssertTrue(contents.contains(DiagnosticsRedactor.emailPlaceholder))

        XCTAssertEqual(router.revealed, [bundleURL])
        XCTAssertEqual(router.opened.count, 1)
        let opened = try XCTUnwrap(router.opened.first)
        XCTAssertEqual(opened.scheme, "mailto")
        XCTAssertTrue(opened.absoluteString.hasPrefix("mailto:feedback@sentwise.ai"))
    }

    func testReportAProblemPassesVerboseFlagToReader() async throws {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            verboseDiagnosticLogging: true
        ))
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [])
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()

        await appState.reportAProblem(
            reader: reader,
            router: router,
            directory: dir,
            isHuntMode: false
        )

        XCTAssertEqual(reader.lastIncludingVerbose, true)
    }

    func testReportAProblemCollectsLogsOffMainThread() async throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = ThreadRecordingDiagnosticsLogReader()
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()

        let url = await appState.reportAProblem(
            reader: reader,
            router: router,
            directory: dir,
            isHuntMode: false
        )

        XCTAssertNotNil(url)
        XCTAssertEqual(reader.wasCalledOnMainThread, false)
    }

    func testVerboseHelperOnlyEvaluatesWhenEnabled() {
        let original = DiagnosticLog.isVerbose
        defer { DiagnosticLog.isVerbose = original }
        var evaluations = 0

        DiagnosticLog.isVerbose = false
        DiagnosticLog.verbose({
            evaluations += 1
            return "disabled"
        }())
        XCTAssertEqual(evaluations, 0)

        DiagnosticLog.isVerbose = true
        DiagnosticLog.verbose({
            evaluations += 1
            return "enabled"
        }())
        XCTAssertEqual(evaluations, 1)
    }

    func testReportAProblemWritesCollectionFailureIntoBundle() async throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [], error: StubDiagnosticsError.logStoreUnavailable)
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()

        let url = await appState.reportAProblem(
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

    func testReportAProblemFallsBackToTemporaryDirectoryWhenPrimaryWriteFails() async throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [])
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()
        let blockedDirectory = dir.appendingPathComponent("not-a-directory")
        let fallbackDirectory = dir.appendingPathComponent("fallback")
        try "occupied".write(to: blockedDirectory, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)

        let url = await appState.reportAProblem(
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

    func testReportAProblemDoesNotOpenMailWhenBundleWriteFails() async throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [])
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()
        let blockedDirectory = dir.appendingPathComponent("not-a-directory")
        let blockedFallback = dir.appendingPathComponent("not-a-fallback-directory")
        try "occupied".write(to: blockedDirectory, atomically: true, encoding: .utf8)
        try "occupied".write(to: blockedFallback, atomically: true, encoding: .utf8)

        let url = await appState.reportAProblem(
            reader: reader,
            router: router,
            directory: blockedDirectory,
            fallbackDirectory: blockedFallback,
            isHuntMode: false
        )

        XCTAssertNil(url)
        let diagnosticsError = try XCTUnwrap(appState.diagnosticsError)
        XCTAssertTrue(diagnosticsError.contains("Couldn't create the diagnostics bundle."), diagnosticsError)
        XCTAssertTrue(router.revealed.isEmpty)
        XCTAssertTrue(router.opened.isEmpty)
    }

    func testReportAProblemSurfacesMailOpenFailureWithFallbackAddress() async throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [])
        let router = RecordingDiagnosticsActionRouter()
        router.openResult = false
        let dir = try tempDirectory()

        let url = await appState.reportAProblem(
            reader: reader,
            router: router,
            directory: dir,
            isHuntMode: false
        )

        let bundleURL = try XCTUnwrap(url)
        XCTAssertEqual(router.revealed, [bundleURL])
        XCTAssertEqual(router.opened.count, 1)
        let diagnosticsError = try XCTUnwrap(appState.diagnosticsError)
        XCTAssertTrue(diagnosticsError.contains("Couldn't open your mail app."), diagnosticsError)
        XCTAssertTrue(diagnosticsError.contains(FeedbackMailComposer.feedbackAddress), diagnosticsError)
        XCTAssertTrue(diagnosticsError.contains(bundleURL.lastPathComponent), diagnosticsError)
    }

    func testReportAProblemClearsPreviousFailureAfterSuccessfulWrite() async throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        appState.diagnosticsError = "Previous diagnostics failure."
        let reader = StubDiagnosticsLogReader(entries: [])
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()

        let url = await appState.reportAProblem(
            reader: reader,
            router: router,
            directory: dir,
            isHuntMode: false
        )

        XCTAssertNotNil(url)
        XCTAssertNil(appState.diagnosticsError)
    }

    func testReportAProblemSuppressesSideEffectsInHuntMode() async throws {
        let persistence = AppStateMemoryPersistence()
        let appState = makeAppState(persistence: persistence)
        let reader = StubDiagnosticsLogReader(entries: [])
        let router = RecordingDiagnosticsActionRouter()
        let dir = try tempDirectory()

        let url = await appState.reportAProblem(
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
