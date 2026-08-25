import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "AppDelegate")

/// Manages the application lifecycle and coordinates the top-level components.
///
/// Responsibilities:
/// - Hide the Dock icon (menu-bar-only app)
/// - Initialize the central `AppState`
/// - Set up the menu bar controller
/// - Start the (currently no-op) update manager
/// - Persist settings on termination
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private let runtime: ProwlHuntRuntime

    /// Central state container for the application.
    private var appState: AppState!

    /// Manages the menu bar icon and dropdown menu.
    private var menuBarController: MenuBarController!

    /// Manages application updates (Sparkle is wired in at the distribution milestone).
    private var updateManager: UpdateManager!

    /// `sentwise://` callbacks can arrive before AppKit has called
    /// `applicationDidFinishLaunching`; hold them until `AppState` can route them.
    private var pendingIncomingURLs: [URL] = []

    var pendingIncomingURLCount: Int { pendingIncomingURLs.count }

    // MARK: - NSApplicationDelegate

    override init() {
        self.runtime = .current
        super.init()
    }

    init(runtime: ProwlHuntRuntime) {
        self.runtime = runtime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon. LSUIElement handles this too,
        // but we set it explicitly to be safe.
        NSApp.setActivationPolicy(.accessory)

        appState = AppState(
            persistence: runtime.makePersistenceProvider(),
            secrets: runtime.makeSecretStore(),
            notifier: runtime.isEnabled ? NullDraftNotifier() : UserNotificationService()
        )
        updateManager = UpdateManager()
        menuBarController = MenuBarController(appState: appState, updateManager: updateManager)
        replayPendingIncomingURLs()
        if runtime.allowsStartupSideEffects {
            updateManager.startUpdater()
        }

        // Prepare native delivery, then read/prompt for permission so the app can
        // flag notification status when off (item 78).
        if runtime.allowsStartupSideEffects {
            appState.notifier.prepareNotificationDelivery()
            Task { await appState.refreshNotificationPermission() }
        }

        // Begin watching reachability so work pauses offline and resumes on
        // reconnect (item 27).
        if runtime.allowsStartupSideEffects {
            appState.startReachabilityMonitoring()
        }

        // First-run onboarding: show the setup assistant until it's completed
        // once. An already-configured install is reconciled to "complete" so
        // existing users are never sent back through the flow.
        if appState.reconcileOnboardingState() {
            if runtime.shouldOpenOnboardingAtLaunch {
                appState.openOnboardingHandler?()
            }
        } else if runtime.allowsStartupSideEffects {
            // Auto-resume watching if an account + LLM are already connected.
            appState.startWatchingIfReady()
        }

        // Resume watching the transcript folder if it was left enabled (item 51).
        if runtime.allowsStartupSideEffects {
            appState.startTranscriptFolderWatchingIfEnabled()
        } else {
            logger.info("Prowl hunt mode enabled; startup watchers and live profile access disabled")
        }

        logger.info("Sentwise launched")
    }

    /// Handles `sentwise://` deep links: the Clerk Google sign-in redirect and the
    /// OpenRouter key-provisioning redirect (item 59). AppKit installs the
    /// GetURL Apple Event handler automatically because the scheme is registered in
    /// `Info.plist` and this delegate method is implemented.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let appState else {
            pendingIncomingURLs.append(contentsOf: urls)
            return
        }
        routeIncomingURLs(urls, appState: appState)
    }

    private func replayPendingIncomingURLs() {
        guard !pendingIncomingURLs.isEmpty else { return }
        let urls = pendingIncomingURLs
        pendingIncomingURLs.removeAll()
        routeIncomingURLs(urls, appState: appState)
    }

    private func routeIncomingURLs(_ urls: [URL], appState: AppState) {
        for url in urls {
            appState.handleIncomingURL(url)
        }
    }

    /// Re-check notification authorization whenever the app returns to the
    /// foreground (item 78): a user who toggled the setting in System Settings and
    /// switched back sees the hint appear — or clear — without relaunching.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard runtime.allowsStartupSideEffects, let appState else { return }
        Task { await appState.refreshNotificationPermission() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any pending edits/settings to disk before quitting.
        appState.flushPendingDraftEdits()
        // Outstanding auto-send countdowns (item 23) must not fire during teardown;
        // their drafts remain pending in the persisted queue.
        appState.cancelAllSendCountdowns()
        appState.stopReachabilityMonitoring()
        appState.stopTranscriptFolderWatching()
        appState.saveSettingsSync()
        logger.info("Sentwise terminating")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
