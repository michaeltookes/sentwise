import Foundation
import os

private let rejectedDeliveryLogger = Logger(
    subsystem: "com.tookes.Sentwise",
    category: "TranscriptFolder"
)

@MainActor
extension WatchedFolderTranscriptSource {

    func handleDeliveryResult(
        _ result: WatchedTranscriptDeliveryResult,
        forKey key: String,
        snapshot: WatchedFolderFileSnapshot
    ) {
        switch result {
        case .accepted, .acceptedWithRollback:
            rejectedDeliveries.removeValue(forKey: key)
            updateSeenVersion(snapshot, forKey: key)
            pendingFileStability.removeValue(forKey: key)
            DiagnosticLog.verbose("Watched transcript delivery marked accepted")
        case .retry:
            if recordRejectedDeliveryRetry(forKey: key, snapshot: snapshot) == .exhausted {
                rejectedDeliveryLogger.error("Watched transcript delivery exhausted retry budget: \(key)")
                updateSeenVersion(snapshot, forKey: key)
                pendingFileStability.removeValue(forKey: key)
                DiagnosticLog.verbose("Watched transcript delivery retry budget exhausted")
            }
        case .deferred:
            recordDeferredDelivery(forKey: key, snapshot: snapshot)
            DiagnosticLog.verbose("Watched transcript delivery deferred")
        }
    }

    func shouldAttemptDelivery(
        forKey key: String,
        snapshot: WatchedFolderFileSnapshot
    ) -> Bool {
        guard let rejected = rejectedDeliveries[key] else { return true }
        guard rejected.snapshot == snapshot else {
            rejectedDeliveries.removeValue(forKey: key)
            return true
        }
        guard !rejected.isDeferred else { return false }
        guard rejected.nextRetryAt <= Date() else {
            scheduleRejectedDeliveryRetry()
            return false
        }
        return true
    }

    func recordRejectedDeliveryRetry(
        forKey key: String,
        snapshot: WatchedFolderFileSnapshot
    ) -> WatchedFolderRejectedDeliveryAction {
        let priorAttempts = rejectedDeliveries[key]?.snapshot == snapshot
            ? rejectedDeliveries[key]?.attempts ?? 0
            : 0
        let attempts = priorAttempts + 1
        if attempts >= max(1, rejectedDeliveryMaxAttempts) {
            rejectedDeliveries.removeValue(forKey: key)
            return .exhausted
        }

        let delay = rejectedDeliveryBackoffDelayNanoseconds(forAttempt: attempts)
        rejectedDeliveries[key] = WatchedFolderRejectedDeliveryState(
            snapshot: snapshot,
            attempts: attempts,
            nextRetryAt: Date().addingTimeInterval(TimeInterval(delay) / 1_000_000_000)
        )
        DiagnosticLog.verbose(
            "Watched transcript delivery retry scheduled; attempt=\(attempts), "
            + "delaySeconds=\(TimeInterval(delay) / 1_000_000_000)"
        )
        rescheduleRejectedDeliveryRetry()
        return .scheduled
    }

    func recordDeferredDelivery(
        forKey key: String,
        snapshot: WatchedFolderFileSnapshot
    ) {
        rejectedDeliveries[key] = WatchedFolderRejectedDeliveryState(
            snapshot: snapshot,
            attempts: 0,
            nextRetryAt: .distantFuture,
            isDeferred: true
        )
        DiagnosticLog.verbose("Watched transcript delivery waiting for app readiness")
    }

    func releaseDeferredDeliveries() {
        let deferredCount = rejectedDeliveries.values.filter(\.isDeferred).count
        rejectedDeliveries = rejectedDeliveries.filter { !$0.value.isDeferred }
        DiagnosticLog.verbose("Released \(deferredCount) deferred watched transcript deliveries")
    }

    func rejectedDeliveryBackoffDelayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let retryIndex = max(0, attempt - 1)
        let shift = min(retryIndex, 16)
        let multiplier = UInt64(1) << UInt64(shift)
        let product = rejectedDeliveryRetryDelayNanoseconds.multipliedReportingOverflow(by: multiplier)
        let uncapped = product.overflow ? UInt64.max : product.partialValue
        return min(uncapped, rejectedDeliveryMaxRetryDelayNanoseconds)
    }

    func rescheduleRejectedDeliveryRetry() {
        rejectedDeliveryRetryTask?.cancel()
        rejectedDeliveryRetryTask = nil
        scheduleRejectedDeliveryRetry()
    }

    func scheduleRejectedDeliveryRetry() {
        guard isRunning, rejectedDeliveryRetryTask == nil else { return }
        guard let nextRetryAt = rejectedDeliveries.values.map(\.nextRetryAt).min() else { return }
        let delay = max(0, nextRetryAt.timeIntervalSinceNow)
        rejectedDeliveryRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                self.rejectedDeliveryRetryTask = nil
                return
            }
            guard self.isRunning else {
                self.rejectedDeliveryRetryTask = nil
                return
            }
            self.rejectedDeliveryRetryTask = nil
            await self.scanForNewTranscripts()
        }
    }
}
