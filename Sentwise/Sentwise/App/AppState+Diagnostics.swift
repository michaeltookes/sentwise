import Foundation

/// "Report a Problem" orchestration (item 36): assemble a redacted diagnostics
/// bundle, save and reveal it in Finder, then open a pre-filled feedback email.
///
/// The heavy lifting lives in small, pure, unit-tested types (`DiagnosticsContext`,
/// `DiagnosticsRedactor`, `DiagnosticsReportBuilder`, `FeedbackMailComposer`) and
/// injectable seams (`DiagnosticsLogReading`, `DiagnosticsActionRouting`); this
/// extension snapshots the app's live state and performs only final UI-facing
/// side effects on the main actor. Kept in its own file so `AppState` stays
/// within lint limits.
extension AppState {

    private enum DiagnosticsBundlePreparation: Sendable {
        case success(url: URL, entryCount: Int)
        case failure(redactedDescription: String)
    }

    private struct DiagnosticsLogCollection: Sendable {
        let entries: [DiagnosticsLogEntry]
        let error: String?
    }

    private struct DiagnosticsBundleRequest: Sendable {
        let reader: DiagnosticsLogReading
        let context: DiagnosticsContext
        let generatedAt: Date
        let since: Date
        let includingVerbose: Bool
        let directory: URL?
        let fallbackDirectory: URL?
    }

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
    ) async -> URL? {
        diagnosticsError = nil
        let context = makeDiagnosticsContext()
        let since = now.addingTimeInterval(-Self.diagnosticsLookbackSeconds)
        let includingVerbose = verboseDiagnosticLogging
        let preparation = await Self.prepareDiagnosticsBundle(
            DiagnosticsBundleRequest(
                reader: reader,
                context: context,
                generatedAt: now,
                since: since,
                includingVerbose: includingVerbose,
                directory: directory,
                fallbackDirectory: fallbackDirectory
            )
        )

        switch preparation {
        case .success(let bundleURL, let entryCount):
            DiagnosticLog.verbose("Generated diagnostics bundle with \(entryCount) log entries")
            // Never launch Finder/Mail during an automated Prowl hunt.
            guard !isHuntMode else { return bundleURL }

            router.revealInFinder(bundleURL)
            if !openFeedbackMail(context: context, bundleURL: bundleURL, router: router) {
                DiagnosticLog.logger.error("Failed to open feedback mail for diagnostics bundle")
                diagnosticsError = Self.feedbackMailOpenFailureMessage(bundleURL: bundleURL)
            }
            return bundleURL

        case .failure(let description):
            DiagnosticLog.logger.error(
                "Failed to write diagnostics bundle: \(description, privacy: .public)"
            )
            diagnosticsError = Self.diagnosticsBundleWriteFailureMessage(
                redactedDescription: description
            )
            return nil
        }
    }

    private nonisolated static func prepareDiagnosticsBundle(
        _ request: DiagnosticsBundleRequest
    ) async -> DiagnosticsBundlePreparation {
        await Task.detached(priority: .utility) {
            let collection = collectDiagnosticLogEntries(
                reader: request.reader,
                since: request.since,
                includingVerbose: request.includingVerbose
            )
            let report = DiagnosticsReportBuilder.build(
                context: request.context,
                entries: collection.entries,
                generatedAt: request.generatedAt,
                collectionError: collection.error
            )

            do {
                let bundleURL = try writeDiagnosticsBundle(
                    report,
                    generatedAt: request.generatedAt,
                    directory: request.directory,
                    fallbackDirectory: request.fallbackDirectory
                )
                return .success(url: bundleURL, entryCount: collection.entries.count)
            } catch {
                let description = DiagnosticsRedactor.redact(error.localizedDescription)
                return .failure(redactedDescription: description)
            }
        }.value
    }

    /// Writes the report text to a timestamped `.txt` file and returns its URL.
    private nonisolated static func writeDiagnosticsBundle(
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

    private nonisolated static func collectDiagnosticLogEntries(
        reader: DiagnosticsLogReading,
        since: Date,
        includingVerbose: Bool
    ) -> DiagnosticsLogCollection {
        do {
            let entries = try reader.recentEntries(since: since, includingVerbose: includingVerbose)
            return DiagnosticsLogCollection(entries: entries, error: nil)
        } catch {
            let description = DiagnosticsRedactor.redact(error.localizedDescription)
            DiagnosticLog.logger.error(
                "Failed to collect diagnostics logs: \(description, privacy: .public)"
            )
            return DiagnosticsLogCollection(entries: [], error: description)
        }
    }

    private nonisolated static func writeDiagnosticsBundle(
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
    ) -> Bool {
        guard let mailto = FeedbackMailComposer.mailtoURL(
            appVersion: context.appVersion,
            buildNumber: context.buildNumber,
            osVersion: context.osVersion,
            bundleFilename: bundleURL.lastPathComponent
        ) else { return false }
        return router.open(mailto)
    }

    static func diagnosticsBundleWriteFailureMessage(redactedDescription: String) -> String {
        let base = "Couldn't create the diagnostics bundle. Check that your Downloads folder "
            + "or disk has space, then try again."
        guard !redactedDescription.isEmpty else { return base }
        return "\(base) \(redactedDescription)"
    }

    static func feedbackMailOpenFailureMessage(bundleURL: URL) -> String {
        "Couldn't open your mail app. Attach \(bundleURL.lastPathComponent) to an email sent to "
            + "\(FeedbackMailComposer.feedbackAddress)."
    }

    /// Downloads folder when available, else the temporary directory.
    nonisolated static func defaultDiagnosticsDirectory() -> URL {
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
    nonisolated static func filenameTimestamp(_ date: Date) -> String {
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
