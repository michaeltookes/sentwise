import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

/// Everything one bulk-cleanup pass needs to know about *what* to do, separate
/// from the connection details (host, credentials) of how to reach the server.
struct IMAPBulkCleanupRequest: Sendable {
    /// The mailbox to scan.
    var mailbox: Mailbox
    /// The filter selecting messages within it.
    var criteria: MailSearchCriteria
    /// The action to apply, or `nil` for a read-only preview.
    var action: MailBulkAction?
    /// Concrete preview selection to apply. When set, apply skips live search.
    var selection: MailBulkSelection?
    /// How many matches to fetch envelopes for (preview only).
    var sampleLimit: Int
    /// Ceiling on how many messages one pass selects.
    var selectionCap: Int
    /// Called after each completed batch while applying.
    var onProgress: (@Sendable (MailBulkProgress) -> Void)?
}

/// The raw outcome of one bulk-cleanup connection, shaped into either a
/// `MailBulkPreview` or a `MailBulkResult` by the calling provider method.
struct IMAPBulkOutcome: Sendable, Equatable {
    /// How many messages the filter selected.
    var matchCount: Int
    /// Envelope sample of the newest matches (preview only; empty when applying).
    var sample: [MailMessage]
    /// True when selection stopped at the cap, so `matchCount` is a lower bound.
    var isPartial: Bool
    /// Concrete UID set selected by the preview, if this was a preview pass.
    var selection: MailBulkSelection?
    /// How many messages the action was actually applied to (0 for a preview).
    var affectedCount: Int
}

extension IMAPMailProvider {
    /// Default cap on how many messages one cleanup pass will select. Keeps a
    /// single operation bounded in time and memory on a mailbox with tens of
    /// thousands of matches; the user simply runs another pass to continue.
    public static var bulkSelectionCap: Int { 5_000 }

    /// Default number of matches shown in a preview.
    public static var bulkPreviewSampleSize: Int { 25 }

    /// Scans `mailbox` for messages matching `criteria` and reports what a bulk
    /// action *would* affect, without changing anything.
    ///
    /// Selection walks the mailbox in bounded sequence windows (see
    /// `SequenceWindow`), so the server never returns an unbounded `* SEARCH`
    /// line — the failure mode that breaks plain search on huge mailboxes
    /// (item 45).
    public func previewBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        sampleLimit: Int = IMAPMailProvider.bulkPreviewSampleSize,
        selectionCap: Int = IMAPMailProvider.bulkSelectionCap
    ) async throws -> MailBulkPreview {
        let outcome = try await runBulkCleanup(credentials, request: IMAPBulkCleanupRequest(
            mailbox: mailbox,
            criteria: criteria,
            action: nil,
            selection: nil,
            sampleLimit: sampleLimit,
            selectionCap: selectionCap,
            onProgress: nil
        ))
        return MailBulkPreview(
            matchCount: outcome.matchCount,
            sample: outcome.sample,
            isPartial: outcome.isPartial,
            selection: outcome.selection
        )
    }

    /// Applies `action` to every message in `mailbox` matching `criteria`.
    ///
    /// Selection completes before any change is made, so relocating messages
    /// cannot shift the sequence numbers the scan is still walking. The action
    /// then runs in bounded batches, reporting progress after each one.
    public func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selection: MailBulkSelection? = nil,
        selectionCap: Int = IMAPMailProvider.bulkSelectionCap,
        onProgress: (@Sendable (MailBulkProgress) -> Void)? = nil
    ) async throws -> MailBulkResult {
        let outcome = try await runBulkCleanup(credentials, request: IMAPBulkCleanupRequest(
            mailbox: mailbox,
            criteria: criteria,
            action: action,
            selection: selection,
            sampleLimit: 0,
            selectionCap: selectionCap,
            onProgress: onProgress
        ))
        return MailBulkResult(action: action, affectedCount: outcome.affectedCount)
    }

    private func runBulkCleanup(
        _ credentials: MailAccountCredentials,
        request: IMAPBulkCleanupRequest
    ) async throws -> IMAPBulkOutcome {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }
        guard request.selectionCap > 0 else {
            return IMAPBulkOutcome(
                matchCount: 0,
                sample: [],
                isPartial: false,
                selection: nil,
                affectedCount: 0
            )
        }

        let naming = credentials.mailboxNaming
        let mailboxName = request.mailbox.imapName(using: naming)
        let destinationName = request.action?.destination?.imapName(using: naming)

        // Moving a message into the folder it already lives in is a no-op at
        // best and a duplicate at worst — refuse rather than churn the mailbox.
        if let destinationName, destinationName == mailboxName {
            throw MailError.commandFailed(
                "The source and destination folders are the same (\(mailboxName))."
            )
        }

        let attempts = ChannelPromiseTracker<IMAPBulkOutcome>()
        // Settle every tracked promise on exit — including losing Happy Eyeballs
        // candidates that never became active — so none is deallocated
        // unfulfilled (backlog item 77). The winner is already claimed by its
        // handler before this runs, so it is untouched.
        defer { attempts.failRemaining(MailError.connectionFailed("The connection attempt was superseded.")) }
        let bootstrap = try makeBulkCleanupBootstrap(
            credentials,
            request: request,
            mailboxName: mailboxName,
            destinationName: destinationName,
            attempts: attempts
        )

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: credentials.host, port: credentials.port).get()
        } catch {
            throw MailError.connectionFailed(String(describing: error))
        }
        guard let outcomeFuture = attempts.future(for: channel) else {
            try? await channel.close().get()
            throw MailError.connectionFailed("The mail connection could not start the cleanup.")
        }

        // A bulk pass walks many windows and batches, so it needs a longer
        // ceiling than a single request — but still a finite one.
        let deadline = channel.eventLoop.scheduleTask(in: .minutes(10)) {
            channel.close(promise: nil)
        }
        defer { deadline.cancel() }

        do {
            let outcome = try await outcomeFuture.get()
            try? await channel.close().get()
            return outcome
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

extension IMAPMailProvider {
    /// Builds the TLS + IMAP pipeline for one cleanup pass.
    fileprivate func makeBulkCleanupBootstrap(
        _ credentials: MailAccountCredentials,
        request: IMAPBulkCleanupRequest,
        mailboxName: String,
        destinationName: String?,
        attempts: ChannelPromiseTracker<IMAPBulkOutcome>
    ) throws -> ClientBootstrap {
        let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        let host = credentials.host
        let email = credentials.email
        let password = credentials.appPassword

        return ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    let handler = IMAPBulkCleanupHandler(
                        email: email,
                        password: password,
                        mailboxName: mailboxName,
                        destinationName: destinationName,
                        request: request,
                        complete: attempts.register(channel)
                    )
                    return channel.pipeline.addHandlers([ssl, IMAPClientHandler(), handler])
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
    }
}
