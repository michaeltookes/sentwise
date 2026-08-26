import Foundation

/// "Report a Problem" orchestration (item 36): assemble a redacted diagnostics
/// bundle, save and reveal it in Finder, then open a pre-filled feedback email.
///
/// The heavy lifting lives in small, pure, unit-tested types (`DiagnosticsContext`,
/// `DiagnosticsRedactor`, `DiagnosticsReportBuilder`, `FeedbackMailComposer`) and
/// injectable seams (`DiagnosticsLogReading`, `DiagnosticsActionRouting`); this
/// extension only wires the app's live state into them and performs the file
/// write. Kept in its own file so `AppState` stays within lint limits.
extension AppState {

    /// The recent window of logs captured into a bundle (last 24 hours).
    static let diagnosticsLookbackSeconds: TimeInterval = 24 * 60 * 60

    /// Builds the non-PII environment context from current app state.
    func makeDiagnosticsContext(
        processInfo: ProcessInfo = .processInfo,
        bundle: Bundle = .main
    ) -> DiagnosticsContext {
        DiagnosticsContext(
            appVersion: DiagnosticsContext.appVersionString(bundle),
            buildNumber: DiagnosticsContext.buildNumberString(bundle),
            osVersion: DiagnosticsContext.osVersionString(processInfo),
            hardwareModel: DiagnosticsContext.hardwareModelIdentifier(),
            providerKind: llmProviderKind.rawValue,
            sendBehavior: sendBehavior.rawValue,
            pollIntervalSeconds: pollIntervalSeconds,
            notificationPermission: Self.describe(notificationPermission),
            verboseLogging: verboseDiagnosticLogging,
            watchedFolderEnabled: transcriptWatchedFolderEnabled
        )
    }

    /// Generates and saves a redacted diagnostics bundle, reveals it in Finder,
    /// and opens a pre-filled feedback email. Returns the bundle URL (if the write
    /// succeeded) so callers/tests can inspect it. In Prowl hunt mode the file is
    /// still written but the Finder/Mail side effects are suppressed.
    @discardableResult
    func reportAProblem(
        reader: DiagnosticsLogReading = OSLogStoreDiagnosticsReader(),
        router: DiagnosticsActionRouting = SystemDiagnosticsActionRouter(),
        now: Date = Date(),
        directory: URL? = nil,
        isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled
    ) -> URL? {
        let context = makeDiagnosticsContext()
        let since = now.addingTimeInterval(-Self.diagnosticsLookbackSeconds)
        let entries = (try? reader.recentEntries(
            since: since,
            includingVerbose: verboseDiagnosticLogging
        )) ?? []
        let report = DiagnosticsReportBuilder.build(context: context, entries: entries, generatedAt: now)
        DiagnosticLog.verbose("Generated diagnostics bundle with \(entries.count) log entries")

        var bundleURL: URL?
        do {
            bundleURL = try writeDiagnosticsBundle(report, generatedAt: now, directory: directory)
        } catch {
            DiagnosticLog.logger.error(
                "Failed to write diagnostics bundle: \(error.localizedDescription, privacy: .public)"
            )
        }

        // Never launch Finder/Mail during an automated Prowl hunt.
        guard !isHuntMode else { return bundleURL }

        if let bundleURL { router.revealInFinder(bundleURL) }
        openFeedbackMail(context: context, bundleURL: bundleURL, router: router)
        return bundleURL
    }

    /// Writes the report text to a timestamped `.txt` file and returns its URL.
    func writeDiagnosticsBundle(
        _ text: String,
        generatedAt: Date = Date(),
        directory: URL? = nil
    ) throws -> URL {
        let dir = directory ?? Self.defaultDiagnosticsDirectory()
        let filename = "Sentwise-Diagnostics-\(Self.filenameTimestamp(generatedAt)).txt"
        let url = dir.appendingPathComponent(filename)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func openFeedbackMail(
        context: DiagnosticsContext,
        bundleURL: URL?,
        router: DiagnosticsActionRouting
    ) {
        let filename = bundleURL?.lastPathComponent ?? "Sentwise-Diagnostics.txt"
        guard let mailto = FeedbackMailComposer.mailtoURL(
            appVersion: context.appVersion,
            buildNumber: context.buildNumber,
            osVersion: context.osVersion,
            bundleFilename: filename
        ) else { return }
        router.open(mailto)
    }

    /// Downloads folder when available, else the temporary directory.
    static func defaultDiagnosticsDirectory() -> URL {
        if let downloads = try? FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            return downloads
        }
        return FileManager.default.temporaryDirectory
    }

    /// A filesystem-safe, sortable timestamp for the bundle filename.
    static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Non-PII label for the notification-permission state.
    static func describe(_ permission: NotificationPermission) -> String {
        switch permission {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not-determined"
        }
    }
}
