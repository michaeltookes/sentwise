import Foundation

/// Construction-time wiring and small system-integration hooks split out of
/// `AppState` so the core file stays within length limits. Behavior is unchanged.
extension AppState {

    /// High-level state of the inbox watcher.
    enum WatchStatus: Equatable {
        case idle
        case watching
        case paused
    }

    /// Builds the production interest-capture client (item 75) from the managed
    /// account session and a live URL-session transport.
    static func makeDefaultInterestClient(
        managedAccount: ManagedAccountService
    ) -> GoogleOAuthInterestRegistering {
        GoogleOAuthInterestClient(sessionProvider: managedAccount, transport: URLSessionTransport())
    }

    /// Wires the notification-action and reachability-change callbacks. Called
    /// once from `init`; reachability monitoring itself is started later by the
    /// app (not here) so headless/test construction never spins up a real
    /// `NWPathMonitor`.
    func installExternalActionHandlers() {
        notifier.onAction = { [weak self] action, identity in
            await self?.handleNotificationAction(action, identity: identity)
        }
        wireUsageMeteringHandlers()
        refreshGoogleOAuthInterestState()
        reachability.onChange = { [weak self] online in
            self?.handleReachabilityChange(online)
        }
    }
}
