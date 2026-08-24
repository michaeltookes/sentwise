import Foundation

/// Menu-bar-facing derived state. Kept in a separate file so `AppState` stays
/// within the file/type length limits.
extension AppState {

    /// The review window carries both queued drafts and the skip log, so it needs
    /// to be reachable when either has content.
    var hasReviewWindowContent: Bool {
        pendingDraftCount > 0 || !skippedMessages.isEmpty
    }

    /// Menu title for opening the review window. Names skipped-only work
    /// explicitly so a zero-draft state does not look like a disabled draft queue.
    var reviewWindowMenuTitle: String {
        if pendingDraftCount > 0 {
            return "Review Drafts (\(pendingDraftCount))…"
        }
        return "Review Skipped Messages (\(skippedMessages.count))…"
    }

    /// The menu points directly at skipped messages when no draft cards are
    /// waiting, so a newly opened review window should land on that tab.
    var opensReviewWindowOnSkippedTab: Bool {
        pendingDraftCount == 0 && !skippedMessages.isEmpty
    }

    /// Human-readable status for the menu bar.
    var statusText: String {
        guard isAccountConnected else { return "No account connected" }
        switch watchStatus {
        case .idle:
            return "Idle"
        case .watching:
            return pendingDraftCount > 0
                ? "\(pendingDraftCount) draft\(pendingDraftCount == 1 ? "" : "s") pending"
                : "Watching inbox"
        case .paused:
            return "Paused"
        }
    }
}
