import Foundation

/// Outcome from the app after the watched-folder source delivers an ingested
/// transcript.
enum WatchedTranscriptDeliveryResult: Equatable {
    /// The transcript is durably handled and may be marked seen.
    case accepted
    /// The transcript is durably handled and may be marked seen, but the accepted
    /// work can be rolled back if the source's final snapshot check fails.
    case acceptedWithRollback(WatchedTranscriptAcceptedRollback)
    /// Retry with a bounded backoff budget for transient post-generation failures.
    case retry
    /// Leave pending until app configuration or credentials change.
    case deferred

    var isAccepted: Bool {
        switch self {
        case .accepted, .acceptedWithRollback:
            return true
        case .retry, .deferred:
            return false
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .accepted:
            return "accepted"
        case .acceptedWithRollback:
            return "acceptedWithRollback"
        case .retry:
            return "retry"
        case .deferred:
            return "deferred"
        }
    }

    static func == (lhs: WatchedTranscriptDeliveryResult, rhs: WatchedTranscriptDeliveryResult) -> Bool {
        switch (lhs, rhs) {
        case (.accepted, .accepted),
             (.acceptedWithRollback, .acceptedWithRollback),
             (.retry, .retry),
             (.deferred, .deferred):
            return true
        default:
            return false
        }
    }
}

typealias WatchedTranscriptShouldCommit = () -> Bool
typealias WatchedTranscriptAcceptedRollback = @MainActor () async -> Void
typealias WatchedTranscriptValidatedDelivery = (
    IngestedTranscript,
    @escaping WatchedTranscriptShouldCommit
) async -> WatchedTranscriptDeliveryResult

struct WatchedFolderRejectedDeliveryState: Equatable {
    var snapshot: WatchedFolderFileSnapshot
    var attempts: Int
    var nextRetryAt: Date
    var isDeferred = false
}

enum WatchedFolderRejectedDeliveryAction: Equatable {
    case scheduled
    case exhausted
}
