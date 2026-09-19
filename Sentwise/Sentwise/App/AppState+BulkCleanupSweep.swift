import SentwiseMail
import Foundation

/// Thrown to unwind a sweep that was superseded (a newer action or a cancel),
/// so the caller returns quietly without reporting completion or an error.
private struct SweepSuperseded: Error {}

/// Thrown when the sweep reaches its safety pass ceiling before a final preview
/// confirms that no matches remain.
private struct SweepPassLimitExceeded: Error {}

/// Thrown when a preview found matches but the apply pass moved none, so the
/// filter has not been verified empty.
private struct SweepNoProgress: Error {}

/// Thrown when Stop was requested and the sweep should finish without claiming
/// the filter is empty.
private struct SweepStopped: Error {}

private enum SweepPassOutcome {
    case exhausted
    case moved(Int)
    case noProgress
    case superseded
}

/// The fixed inputs of a multi-pass sweep, threaded through each pass so the
/// per-pass helper stays small (item 49).
private struct SweepContext {
    var query: MailboxBrowserQuery
    var action: MailBulkAction
    var criteria: MailSearchCriteria
    var credentials: MailAccountCredentials
    var account: BulkCleanupAccountIdentity
    var generation: Int
}

/// The verify-until-stable bulk sweep (item 49): repeatedly clean a filter
/// until the mailbox stops revealing older matches. Split out of
/// `AppState+BulkCleanup` to keep both files within length limits.
extension AppState {

    /// Ceiling on sweep passes, a safety backstop against an unexpected
    /// non-terminating loop. At up to `bulkSelectionCap` moved per pass this
    /// covers far more mail than any real mailbox holds.
    static let bulkSweepMaxPasses = 200

    /// How many consecutive transient failures (e.g. a rate-limit "try again
    /// later") to ride out before giving up and reporting partial progress.
    static let bulkSweepMaxTransientRetries = 5

    /// Repeatedly previews and applies a move action until the filter reports no
    /// remaining matches, or reports an incomplete sweep when progress stops.
    ///
    /// att.net/Yahoo exposes only ~10,000 messages over IMAP at once, so a single
    /// pass can only reach the matches inside that window; removing them slides
    /// older mail into view, which the next pass then reaches. Looping until the
    /// count reaches zero is the only way "clean all" actually cleans all on such
    /// a mailbox (item 49). Only meaningful for actions that *remove* messages —
    /// marking read leaves the window unchanged, so callers route that to the
    /// single-pass path instead.
    func applyBulkCleanupSweep() async {
        let credentials = browserCredentials
        guard credentials.isComplete else {
            bulk.error = "Connect an account first."
            return
        }
        guard let applyContext = validatedBulkApplyContext() else { return }
        let action = applyContext.action
        guard action.destination != nil else {
            // No source-shrinking effect, so a sweep cannot make progress past
            // the visibility cap; a single pass is the honest behavior.
            await applyBulkCleanup()
            return
        }

        let requestGeneration = nextBulkGeneration()
        let account = applyContext.previewAccount
        let context = SweepContext(
            query: applyContext.previewQuery,
            action: action,
            criteria: applyContext.criteria,
            credentials: applyContext.credentials,
            account: account,
            generation: requestGeneration
        )
        bulk.reset()
        bulk.isApplying = true
        bulk.sweepMovedSoFar = 0
        defer {
            if bulkGeneration == requestGeneration {
                bulk.isApplying = false
                bulk.sweepMovedSoFar = nil
                bulk.isCancellingSweep = false
            }
        }

        do {
            let total = try await sweepUntilClear(context)
            guard isCurrentBulkCleanupApply(requestGeneration, account: account) else { return }
            bulk.completionMessage = Self.bulkCompletionMessage(
                for: MailBulkResult(action: action, affectedCount: total)
            )
            await runMailboxSearch()
        } catch is SweepStopped {
            guard isCurrentBulkCleanupApply(requestGeneration, account: account) else { return }
            bulk.completionMessage = Self.sweepStoppedMessage(movedSoFar: bulk.sweepMovedSoFar ?? 0)
            await runMailboxSearch()
        } catch is SweepSuperseded {
            return
        } catch {
            guard isCurrentBulkCleanupApply(requestGeneration, account: account) else { return }
            bulk.error = Self.sweepErrorMessage(error, movedSoFar: bulk.sweepMovedSoFar ?? 0)
            await runMailboxSearch()
        }
    }

    /// Loops preview+apply, pacing between passes and riding out transient
    /// rate-limit failures, until the filter is exhausted. Returns the total
    /// moved; throws on a non-transient error, a no-progress pass, after too many
    /// consecutive transient failures, or when the pass limit is reached before
    /// the filter is verified empty.
    private func sweepUntilClear(_ context: SweepContext) async throws -> Int {
        var total = 0
        var transientFailures = 0
        for _ in 0..<Self.bulkSweepMaxPasses {
            let outcome: SweepPassOutcome
            do {
                outcome = try await runOneSweepPass(context)
            } catch {
                guard try await shouldRetryAfterTransientFailure(error, &transientFailures, context) else {
                    throw error
                }
                continue
            }
            transientFailures = 0
            switch outcome {
            case .exhausted:
                return total
            case .moved(let count):
                total += count
                bulk.sweepMovedSoFar = total
                if bulk.isCancellingSweep { throw SweepStopped() }
            case .noProgress:
                throw SweepNoProgress()
            case .superseded:
                throw SweepSuperseded()
            }
            // Breathe between passes so a rapid burst of full scans does not trip
            // the provider's rate limit.
            try? await Task.sleep(nanoseconds: bulkSweepPacingNanoseconds)
        }
        throw SweepPassLimitExceeded()
    }

    /// Whether a failed pass should be retried: only transient failures, only
    /// while still current, and only up to the retry ceiling. Backs off (longer
    /// each time) before returning `true`.
    private func shouldRetryAfterTransientFailure(
        _ error: Error,
        _ transientFailures: inout Int,
        _ context: SweepContext
    ) async throws -> Bool {
        transientFailures += 1
        guard Self.isTransientBulkError(error),
              transientFailures <= Self.bulkSweepMaxTransientRetries,
              isCurrentBulkCleanupApply(context.generation, account: context.account) else {
            return false
        }
        try? await Task.sleep(nanoseconds: bulkSweepPacingNanoseconds &* UInt64(transientFailures))
        return true
    }

    /// A rate limit or a temporary server hiccup is retryable; a rejected
    /// command (e.g. no MOVE support) is not.
    static func isTransientBulkError(_ error: Error) -> Bool {
        guard case MailError.commandFailed(let text) = error else { return false }
        let lowered = text.lowercased()
        return ["try again", "server error", "temporar", "timeout", "too many", "busy", "unavailable"]
            .contains { lowered.contains($0) }
    }

    /// Error text that preserves partial progress: a sweep that moved thousands
    /// before being throttled should say so and invite another run, not read as
    /// a total failure.
    static func sweepErrorMessage(_ error: Error, movedSoFar: Int) -> String {
        if error is SweepPassLimitExceeded {
            let noun = movedSoFar == 1 ? "message" : "messages"
            return "Moved \(movedSoFar) \(noun), but stopped at the sweep pass limit "
                + "before verifying the filter was empty. Run cleanup again to continue."
        }
        if error is SweepNoProgress {
            return incompleteSweepMessage(
                movedSoFar: movedSoFar,
                reason: "a sweep pass found matches but moved 0 messages"
            )
        }
        let base = message(for: error)
        guard movedSoFar > 0 else { return base }
        let noun = movedSoFar == 1 ? "message" : "messages"
        guard Self.isTransientBulkError(error) else {
            return permanentSweepErrorMessage(movedSoFar: movedSoFar, noun: noun, base: base)
        }
        return transientSweepErrorMessage(movedSoFar: movedSoFar, noun: noun, base: base)
    }

    static func incompleteSweepMessage(movedSoFar: Int, reason: String) -> String {
        let prefix: String
        if movedSoFar > 0 {
            let noun = movedSoFar == 1 ? "message" : "messages"
            prefix = "Moved \(movedSoFar) \(noun), but"
        } else {
            prefix = "Stopped before moving any messages because"
        }
        return "\(prefix) \(reason), so the filter was not verified empty. "
            + "Run cleanup again to continue."
    }

    static func permanentSweepErrorMessage(movedSoFar: Int, noun: String, base: String) -> String {
        "Moved \(movedSoFar) \(noun) before cleanup stopped. \(base)"
    }

    static func transientSweepErrorMessage(movedSoFar: Int, noun: String, base: String) -> String {
        "Moved \(movedSoFar) \(noun) before the server asked us to slow down. "
            + "Wait a moment and run it again to continue. (\(base))"
    }

    static func sweepStoppedMessage(movedSoFar: Int) -> String {
        "Stopped after moving \(movedSoFar) message\(movedSoFar == 1 ? "" : "s")."
    }

    /// One preview+apply pass of a sweep.
    private func runOneSweepPass(_ context: SweepContext) async throws -> SweepPassOutcome {
        guard isCurrentBulkCleanupApply(context.generation, account: context.account) else {
            return .superseded
        }
        guard !bulk.isCancellingSweep else { throw SweepStopped() }
        let preview = try await mailProvider.previewBulkCleanup(
            context.credentials,
            mailbox: context.query.mailbox,
            criteria: context.criteria,
            sampleLimit: 0,
            selectionCap: Self.bulkSelectionCap
        )
        guard isCurrentBulkCleanupApply(context.generation, account: context.account) else {
            return .superseded
        }
        guard !bulk.isCancellingSweep else { throw SweepStopped() }
        guard preview.matchCount > 0, let selection = preview.selection else { return .exhausted }

        let result = try await mailProvider.applyBulkCleanup(
            context.credentials,
            mailbox: context.query.mailbox,
            criteria: context.criteria,
            action: context.action,
            selection: selection,
            selectionCap: Self.bulkSelectionCap,
            onProgress: nil
        )
        guard isCurrentBulkCleanupApply(context.generation, account: context.account) else {
            return .superseded
        }
        return result.affectedCount > 0 ? .moved(result.affectedCount) : .noProgress
    }

    /// Stops an in-flight sweep after the current pass reports what it moved.
    /// For non-sweep work, supersedes the request so later stages no-op.
    func cancelBulkCleanup() {
        guard bulk.isSweeping else {
            _ = nextBulkGeneration()
            bulk.isApplying = false
            bulk.isPreviewing = false
            Task { await runMailboxSearch() }
            return
        }
        bulk.isCancellingSweep = true
        bulk.isPreviewing = false
    }
}
