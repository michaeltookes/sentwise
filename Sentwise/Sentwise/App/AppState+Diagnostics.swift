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
    /// still written but the Finder/Mail side effects are suppressed. If both the
    /// primary and fallback writes fail, no misleading feedback email is opened.
    @discardableResult
    func reportAProblem(
        reader: DiagnosticsLogReading = OSLogStoreDiagnosticsReader(),
        router: DiagnosticsActionRouting = SystemDiagnosticsActionRouter(),
        now: Date = Date(),
        directory: URL? = nil,
        fallbackDirectory: URL? = nil,
        isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled
    ) -> URL? {
        let context = makeDiagnosticsContext()
        let since = now.addingTimeInterval(-Self.diagnosticsLookbackSeconds)
        let collection = collectDiagnosticLogEntries(
            reader: reader,
            since: since,
            includingVerbose: verboseDiagnosticLogging
        )
        let report = DiagnosticsReportBuilder.build(
            context: context,
            entries: collection.entries,
            generatedAt: now,
            collectionError: collection.error
        )
        DiagnosticLog.verbose("Generated diagnostics bundle with \(collection.entries.count) log entries")

        let bundleURL: URL
        do {
            bundleURL = try writeDiagnosticsBundle(
                report,
                generatedAt: now,
                directory: directory,
                fallbackDirectory: fallbackDirectory
            )
        } catch {
            let description = DiagnosticsRedactor.redact(error.localizedDescription)
            DiagnosticLog.logger.error(
                "Failed to write diagnostics bundle: \(description, privacy: .public)"
            )
            return nil
        }

        // Never launch Finder/Mail during an automated Prowl hunt.
        guard !isHuntMode else { return bundleURL }

        router.revealInFinder(bundleURL)
        openFeedbackMail(context: context, bundleURL: bundleURL, router: router)
        return bundleURL
    }

    /// Writes the report text to a timestamped `.txt` file and returns its URL.
    func writeDiagnosticsBundle(
        _ text: String,
        generatedAt: Date = Date(),
        directory: URL? = nil,
        fallbackDirectory: URL? = nil
    ) throws -> URL {
        let filename = "Sentwise-Diagnostics-\(Self.filenameTimestamp(generatedAt)).txt"
        let primaryDirectory = directory ?? Self.defaultDiagnosticsDirectory()
        do {
            return try writeDiagnosticsBundle(text, filename: filename, directory: primaryDirectory)
        } catch {
            let fallback = fallbackDirectory ?? FileManager.default.temporaryDirectory
            guard primaryDirectory.standardizedFileURL != fallback.standardizedFileURL else {
                throw error
            }
            let description = DiagnosticsRedactor.redact(error.localizedDescription)
            DiagnosticLog.logger.error(
                "Failed to write diagnostics bundle in primary directory; retrying temp: \(description, privacy: .public)"
            )
            return try writeDiagnosticsBundle(text, filename: filename, directory: fallback)
        }
    }

    private func collectDiagnosticLogEntries(
        reader: DiagnosticsLogReading,
        since: Date,
        includingVerbose: Bool
    ) -> (entries: [DiagnosticsLogEntry], error: String?) {
        do {
            return (try reader.recentEntries(since: since, includingVerbose: includingVerbose), nil)
        } catch {
            let description = DiagnosticsRedactor.redact(error.localizedDescription)
            DiagnosticLog.logger.error(
                "Failed to collect diagnostics logs: \(description, privacy: .public)"
            )
            return ([], description)
        }
    }

    private func writeDiagnosticsBundle(
        _ text: String,
        filename: String,
        directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func openFeedbackMail(
        context: DiagnosticsContext,
        bundleURL: URL,
        router: DiagnosticsActionRouting
    ) {
        guard let mailto = FeedbackMailComposer.mailtoURL(
            appVersion: context.appVersion,
            buildNumber: context.buildNumber,
            osVersion: context.osVersion,
            bundleFilename: bundleURL.lastPathComponent
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
