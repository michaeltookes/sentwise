import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "URLCallback")

/// Routes an incoming `sentwise://` deep link to the right sign-in/provisioning
/// completion (item 59). Called from `AppDelegate.application(_:open:)`.
extension AppState {

    /// Dispatches a custom-scheme URL. Unrecognized URLs (foreign scheme, unknown
    /// host, missing parameter) are logged and ignored — never acted on — and no
    /// URL is acted on during a Prowl hunt.
    func handleIncomingURL(_ url: URL) {
        guard let callback = routableCallback(for: url) else { return }
        // The browser handed control back; put the app in front so the result is seen.
        NSApp.activate(ignoringOtherApps: true)
        switch callback {
        case .managedOAuth(let nonce):
            Task { await handleManagedOAuthCallback(nonce: nonce) }
        case .openRouter(let code):
            Task { await handleOpenRouterCallback(code: code) }
        }
    }

    /// The callback to act on, or `nil` when the app must ignore this URL: during
    /// a Prowl hunt (completion paths touch the network / account, so a hunt must
    /// never reach them even via a stray deep link), or when the URL doesn't parse
    /// into a known callback. `isHuntMode` is injectable for tests.
    func routableCallback(
        for url: URL,
        isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled
    ) -> SentwiseURLCallback? {
        guard !isHuntMode else {
            logger.info("Ignoring incoming URL during Prowl hunt")
            return nil
        }
        guard let callback = SentwiseURLCallback(url: url) else {
            logger.error("Ignoring unrecognized incoming URL")
            return nil
        }
        return callback
    }
}
