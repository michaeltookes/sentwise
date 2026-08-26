import AppKit
import SwiftUI

/// Manages the menu bar icon and dropdown menu.
///
/// The menu bar is the primary access point for Sentwise. The menu is
/// rebuilt on demand (`menuNeedsUpdate`) so the status line and toggle states
/// always reflect current `AppState`.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private let appState: AppState
    private let updateManager: UpdateManager

    /// The native settings window (item 65), managed by its own controller.
    private let settingsWindowController: SettingsWindowController

    /// The draft-review window, created lazily.
    private var reviewWindow: NSWindow?
    private var reviewCloseObserver: NSObjectProtocol?
    private let reviewSelection = ReviewWindowSelection()

    /// The first-run onboarding window, created lazily.
    private var onboardingWindow: NSWindow?
    private var onboardingCloseObserver: NSObjectProtocol?

    /// The mailbox browser window, created lazily.
    private var browserWindow: NSWindow?
    private var browserCloseObserver: NSObjectProtocol?

    /// The activity-history window, created lazily.
    private var activityWindow: NSWindow?
    private var activityCloseObserver: NSObjectProtocol?

    /// The post-call follow-up composer window (item 51), managed on its own.
    private let followUpComposer = FollowUpComposerWindow()

    // MARK: - Initialization

    init(appState: AppState, updateManager: UpdateManager) {
        self.appState = appState
        self.updateManager = updateManager
        self.settingsWindowController = SettingsWindowController(
            appState: appState,
            updateManager: updateManager
        )
        super.init()
        setupStatusItem()
        // A notification "open" action (or approve/deny while closed) surfaces
        // the review window.
        appState.openReviewHandler = { [weak self] in self?.openReview() }
        // The app delegate (at first launch) or the menu opens onboarding.
        appState.openOnboardingHandler = { [weak self] in self?.openOnboarding() }
    }

    deinit {
        if let observer = reviewCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = onboardingCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = browserCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = activityCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "envelope.badge",
                accessibilityDescription: "Sentwise"
            )
            button.image?.isTemplate = true  // Adapts to light/dark menu bar.
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Re-check notification authorization when the menu opens (item 78) so the
        // "notifications are off" row appears/clears; the async result lands before
        // the next open, and applicationDidBecomeActive keeps it fresh meanwhile.
        Task { await appState.refreshNotificationPermission() }
        menu.removeAllItems()
        for item in buildMenuItems() {
            menu.addItem(item)
        }
    }

    /// Account-dependent action items (review, browse, watch) shown between the
    /// status line and the settings section.
    private func contextualActionItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // New follow-up from a call transcript (item 51) — the flagship workflow.
        if appState.isAccountConnected {
            let followUp = NSMenuItem(
                title: "New Follow-up from Transcript…",
                action: #selector(openFollowUpComposerMenu),
                keyEquivalent: "n"
            )
            followUp.target = self
            followUp.setAccessibilityIdentifier("openFollowUpComposer")
            items.append(followUp)
        }

        // Review window (pending drafts or skipped messages with override).
        if appState.hasReviewWindowContent {
            let review = NSMenuItem(
                title: appState.reviewWindowMenuTitle,
                action: #selector(openReviewMenu),
                keyEquivalent: "r"
            )
            review.target = self
            review.setAccessibilityIdentifier("openReviewWindow")
            items.append(review)
        }

        // Browse Mailbox (only when an account is connected — search needs it).
        if appState.isAccountConnected {
            let browse = NSMenuItem(
                title: "Browse Mailbox…",
                action: #selector(openBrowserMenu),
                keyEquivalent: "b"
            )
            browse.target = self
            browse.setAccessibilityIdentifier("openBrowseMailbox")
            items.append(browse)
        }

        // Start / Pause watching (only when an account + LLM are connected).
        if appState.canWatch {
            let watching = appState.watchStatus == .watching
            let toggle = NSMenuItem(
                title: watching ? "Pause Watching" : "Start Watching",
                action: #selector(toggleWatching),
                keyEquivalent: ""
            )
            toggle.target = self
            items.append(toggle)
        }

        return items
    }

    private func buildMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // Header (disabled label)
        let header = NSMenuItem(title: "Sentwise", action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)

        // Status line (disabled label)
        let status = NSMenuItem(title: appState.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        items.append(status)

        // Notifications-off hint (item 78): shown only while authorization is off,
        // so it never nags. Clicking it deep-links to System Settings.
        if appState.notificationsBlocked {
            let warn = NSMenuItem(
                title: "⚠ Notifications are off — turn on…",
                action: #selector(openNotificationSettingsMenu),
                keyEquivalent: ""
            )
            warn.target = self
            warn.toolTip = "You won't see when drafts are ready. "
                + "Open Review Drafts from this menu to review them anytime."
            warn.setAccessibilityIdentifier("notificationsDisabledWarning")
            items.append(warn)
        }

        items.append(contentsOf: contextualActionItems())

        items.append(.separator())

        // Setup Assistant…
        let setup = NSMenuItem(title: "Setup Assistant…", action: #selector(openOnboardingMenu), keyEquivalent: "")
        setup.target = self
        setup.setAccessibilityIdentifier("openSetupAssistant")
        items.append(setup)

        // Settings…
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.setAccessibilityIdentifier("openSettings")
        items.append(settings)

        // Activity History… (always available; the log persists across launches).
        let activity = NSMenuItem(title: "Activity History…", action: #selector(openActivityMenu), keyEquivalent: "")
        activity.target = self
        activity.setAccessibilityIdentifier("openActivityMenu")
        items.append(activity)

        items.append(.separator())

        // Launch at Login toggle
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = appState.launchAtLogin ? .on : .off
        items.append(login)

        // Check for Updates
        let updateTitle = updateManager.isConfigured
            ? "Check for Updates…"
            : "Check for Updates (Unavailable)"
        let update = NSMenuItem(title: updateTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = updateManager.canCheckForUpdates
        if let reason = updateManager.unavailableReason {
            update.toolTip = reason
        }
        items.append(update)

        items.append(.separator())

        // Quit
        let quit = NSMenuItem(title: "Quit Sentwise", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        items.append(quit)

        return items
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin() {
        appState.setLaunchAtLogin(!appState.launchAtLogin)
    }

    @objc private func toggleWatching() {
        appState.toggleWatching()
    }

    @objc private func openReviewMenu() {
        openReview()
    }

    @objc private func openOnboardingMenu() {
        openOnboarding()
    }

    @objc private func openBrowserMenu() {
        openBrowser()
    }

    @objc private func openActivityMenu() {
        openActivity()
    }

    @objc private func openNotificationSettingsMenu() {
        appState.openNotificationSystemSettings()
    }

    @objc private func openFollowUpComposerMenu() {
        followUpComposer.present(appState: appState)
    }

    func openBrowser() {
        if browserWindow == nil {
            let view = MailboxBrowserView()
                .environmentObject(appState)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Browse Mailbox"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            window.setAccessibilityLabel("Browse Mailbox")
            browserWindow = window

            browserCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    if let observer = self?.browserCloseObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self?.browserCloseObserver = nil
                    }
                    self?.browserWindow = nil
                }
            }
        }

        browserWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(initialStep: appState.onboardingResumeStep) { [weak self] in
                self?.onboardingWindow?.close()
            }
            .environmentObject(appState)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sentwise Setup"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            window.setAccessibilityLabel("Sentwise Setup")
            onboardingWindow = window

            onboardingCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    if let observer = self?.onboardingCloseObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self?.onboardingCloseObserver = nil
                    }
                    self?.onboardingWindow = nil
                }
            }
        }

        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openReview() {
        reviewSelection.selectedTab = appState.opensReviewWindowOnSkippedTab
            ? .skipped
            : .drafts

        if reviewWindow == nil {
            let view = PendingDraftsView(selection: reviewSelection)
                .environmentObject(appState)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Review Drafts"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            window.setAccessibilityLabel("Review Drafts")
            reviewWindow = window

            reviewCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    if let observer = self?.reviewCloseObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self?.reviewCloseObserver = nil
                    }
                    self?.reviewWindow = nil
                }
            }
        }

        reviewWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openActivity() {
        if activityWindow == nil {
            let view = ActivityHistoryView()
                .environmentObject(appState)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Activity History"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            window.setAccessibilityLabel("Activity History")
            activityWindow = window

            activityCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    if let observer = self?.activityCloseObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self?.activityCloseObserver = nil
                    }
                    self?.activityWindow = nil
                }
            }
        }

        activityWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updateManager.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        settingsWindowController.show()
    }
}
