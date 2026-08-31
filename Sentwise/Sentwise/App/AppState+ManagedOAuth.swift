import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedOAuth")

/// Managed-account Google sign-in via Clerk's OAuth flow (item 59), plus the
/// shared post-sign-in finalization used by both the email-code and OAuth paths.
/// Kept in its own file so `AppState+ManagedAccount` stays within length limits.
extension AppState {

    /// The custom-scheme URL Clerk redirects back to after the Google handshake.
    /// Registered in `Info.plist` (`CFBundleURLTypes`) and must be added as an
    /// allowed redirect URL in the Clerk dashboard.
    /// Clerk redirects the browser here (an HTTPS landing page on the Worker that
    /// shows "You're signed in" and forwards the nonce to `sentwise://oauth-callback`).
    /// Redirecting straight to the custom scheme leaves the browser tab spinning.
    static var managedOAuthRedirectURL: String {
        ManagedInference.baseURL.appendingPathComponent("auth/callback").absoluteString
    }

    /// Shared success path once a session is stored (email code or OAuth): records
    /// the account, marks managed verified when it's the active provider, and
    /// resumes any watchers that a re-auth had paused.
    func finalizeManagedSignIn(email: String, accountID: String) {
        clearManagedQuotaCache()
        didDeleteManagedAccount = false
        managedAccountEmail = email
        managedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        managedEmailInput = email
        managedCodeInput = ""
        pendingManagedSignInEmail = nil
        pendingManagedSignInActivatesProvider = true
        managedSignInStage = .idle
        isManagedSignedIn = true

        // When managed is the active provider path, mark it verified so drafting
        // and the connected UI light up. The model is always the managed default.
        if llmProviderKind == .managed {
            verifiedLLMModel = llmProviderKind.defaultModel
            refreshLLMConnectionStatus()
            resetDraftPreviewForLLMChange()
        }
        saveSettings()
        // Reflect this account's prior "notify me about Sign in with Google" choice
        // so the item-75 capture button isn't re-offered after a click (item 75).
        refreshGoogleOAuthInterestState()
        resumeInboxWatchingAfterManagedReauthenticationIfNeeded()
        startTranscriptFolderWatchingIfEnabled()
        // Pull the current weekly allotment now that we can authenticate (item 56b).
        Task { await refreshManagedQuota() }
    }

    /// Starts Google sign-in: asks Clerk for the hosted URL and opens it in the
    /// default browser. `openURL` is injectable so the browser hand-off is
    /// suppressed in tests. In Prowl hunt mode this is a deterministic, fully-offline
    /// fake: it advances to the `awaitingBrowser` panel WITHOUT opening a real
    /// browser or calling Clerk (item 70); a hunt completes it via
    /// `completeManagedGoogleSignInForHunt`. `isHuntMode` is injectable for tests.
    func startManagedGoogleSignIn(
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) },
        activatesManagedProvider: Bool = true,
        isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled
    ) async {
        managedError = nil
        if isHuntMode {
            // Deterministic offline fake: show the browser-wait panel, open nothing.
            pendingManagedSignInActivatesProvider = activatesManagedProvider
            managedSignInStage = .awaitingBrowser
            return
        }
        managedBusyAction = .google
        defer { managedBusyAction = nil }
        do {
            let url = try await managedAccount.startGoogleSignIn(redirectURL: Self.managedOAuthRedirectURL)
            openURL(url)
            pendingManagedSignInActivatesProvider = activatesManagedProvider
            managedSignInStage = .awaitingBrowser
        } catch {
            pendingManagedSignInActivatesProvider = true
            managedError = Self.managedMessage(for: error)
        }
    }

    /// Completes Google sign-in from the `sentwise://oauth-callback` redirect.
    func handleManagedOAuthCallback(nonce: String) async {
        managedError = nil
        managedBusyAction = .oauthCallback
        defer { managedBusyAction = nil }
        let result: ManagedAccountSignInResult
        do {
            result = try await managedAccount.completeGoogleSignIn(rotatingTokenNonce: nonce)
        } catch {
            managedError = Self.managedMessage(for: error)
            if managedSignInStage == .awaitingBrowser {
                pendingManagedSignInActivatesProvider = true
                managedSignInStage = .idle
            }
            return
        }
        if pendingManagedSignInActivatesProvider, llmProviderKind != .managed {
            selectLLMProvider(.managed)
        }
        let email = result.displayIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "your Google account"
        finalizeManagedSignIn(email: email, accountID: result.accountIdentifier)
        logger.info("Managed Google sign-in completed")
    }
}
