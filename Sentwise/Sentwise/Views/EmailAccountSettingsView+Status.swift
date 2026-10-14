import SwiftUI

extension EmailAccountSettingsView {
    /// A per-account connection/health line for the mailboxes list.
    func accountStatusLabel(for account: SavedMailAccount) -> String {
        // Item 108: Starter has no inbox watcher at all — communicate that where the
        // watch status normally shows, rather than a misleading "Connected".
        if !appState.inboxWatchingAllowedForTier, appState.isConnectedAccount(email: account.email) {
            return AppState.inboxWatchingProFeatureMessage
        }
        if let error = appState.watchError(forAccountEmail: account.email), !error.isEmpty {
            return error
        }
        switch appState.watchStatus(forAccountEmail: account.email) {
        case .watching: return "Watching"
        case .paused: return "Paused"
        case .idle: return appState.isConnectedAccount(email: account.email) ? "Connected" : "Not watching"
        }
    }

    func accountStatusColor(for account: SavedMailAccount) -> Color {
        if let error = appState.watchError(forAccountEmail: account.email), !error.isEmpty {
            return .red
        }
        return appState.watchStatus(forAccountEmail: account.email) == .watching ? .green : .secondary
    }
}
