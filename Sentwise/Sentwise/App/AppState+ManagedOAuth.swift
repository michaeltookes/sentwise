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

    static func newBrowserCallbackFlowID() -> String {
        PKCEGenerator.randomURLSafeString(byteCount: 16)
    }

    private static func managedOAuthRedirectURL(flowID: String) -> String {
        var components = URLComponents(
            url: ManagedInference.baseURL.appendingPathComponent("auth/callback"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "state", value: flowID)]
        return components?.url?.absoluteString ?? managedOAuthRedirectURL
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
        pendingManagedSignInMessageSurface = .shared
        managedSignInStage = .idle
        isManagedSignedIn = true
        clearManagedOAuthMessageSurfaceBestEffort()
        clearManagedOAuthFlowIDBestEffort()
        clearCanceledManagedOAuthCallbackSurfaceBestEffort()

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
        isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled,
        messageSurface: TransientMessageSurface = .shared
    ) async {
        setManagedError(nil, for: messageSurface)
        pendingManagedSignInMessageSurface = messageSurface
        if isHuntMode {
            // Deterministic offline fake: show the browser-wait panel, open nothing.
            pendingManagedSignInActivatesProvider = activatesManagedProvider
            managedSignInStage = .awaitingBrowser
            return
        }
        let settingsMessageGeneration = settingsTransientMessageGeneration
        managedBusyAction = .google
        defer { managedBusyAction = nil }
        let flowID = Self.newBrowserCallbackFlowID()
        do {
            try secrets.set(flowID, for: .managedOAuthFlowID)
        } catch {
            reportManagedErrorIfCurrent(
                Self.managedMessage(for: error),
                generation: settingsMessageGeneration,
                surface: messageSurface
            )
            return
        }
        do {
            let url = try await managedAccount.startGoogleSignIn(
                redirectURL: Self.managedOAuthRedirectURL(flowID: flowID)
            )
            persistManagedOAuthMessageSurfaceBestEffort(messageSurface)
            openURL(url)
            pendingManagedSignInActivatesProvider = activatesManagedProvider
            managedSignInStage = .awaitingBrowser
        } catch {
            clearManagedOAuthFlowIDBestEffort()
            pendingManagedSignInActivatesProvider = true
            reportManagedErrorIfCurrent(
                Self.managedMessage(for: error),
                generation: settingsMessageGeneration,
                surface: messageSurface
            )
        }
    }

    /// Completes Google sign-in from the `sentwise://oauth-callback` redirect.
    func handleManagedOAuthCallback(nonce: String, flowID: String? = nil) async {
        guard shouldHandleManagedOAuthCallback(flowID: flowID) else { return }
        let messageSurface = currentManagedOAuthMessageSurface()
        let settingsMessageGeneration = settingsTransientMessageGeneration
        let signInID: String?
        do {
            signInID = try secrets.value(for: .managedOAuthSignInID)
        } catch {
            reportManagedOAuthCallbackStateReadErrorForUnknownSurface(error, generation: settingsMessageGeneration)
            return
        }
        if managedSignInStage == .idle,
           signInID?.isEmpty != false,
           consumeCanceledManagedOAuthCallbackSurface() != nil {
            pendingManagedSignInMessageSurface = .shared
            return
        }
        setManagedError(nil, for: messageSurface)
        managedBusyAction = .oauthCallback
        defer { managedBusyAction = nil }
        let result: ManagedAccountSignInResult
        do {
            result = try await managedAccount.completeGoogleSignIn(rotatingTokenNonce: nonce)
        } catch {
            guard shouldContinueManagedOAuthCallback(
                signInID: signInID,
                flowID: flowID,
                generation: settingsMessageGeneration,
                surface: messageSurface
            ) else { return }
            reportManagedOAuthCallbackError(
                Self.managedMessage(for: error),
                generation: settingsMessageGeneration,
                surface: messageSurface
            )
            if managedSignInStage == .awaitingBrowser {
                pendingManagedSignInActivatesProvider = true
                pendingManagedSignInMessageSurface = .shared
                clearManagedOAuthFlowIDBestEffort()
                managedSignInStage = .idle
            }
            return
        }
        do {
            guard try managedOAuthCallbackFlowMatches(flowID: flowID, resetCanceledWhenMissing: false) else {
                await discardIgnoredManagedOAuthSuccessIfEnded()
                return
            }
        } catch {
            reportManagedOAuthCallbackStateReadError(error, generation: settingsMessageGeneration, surface: messageSurface)
            return
        }
        if pendingManagedSignInActivatesProvider, llmProviderKind != .managed {
            selectLLMProvider(.managed, messageSurface: messageSurface)
        }
        let email = result.displayIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "your Google account"
        finalizeManagedSignIn(email: email, accountID: result.accountIdentifier)
        logger.info("Managed Google sign-in completed")
    }

    private func shouldContinueManagedOAuthCallback(
        signInID: String?,
        flowID: String?,
        generation: UInt64,
        surface: TransientMessageSurface
    ) -> Bool {
        do {
            guard try managedOAuthCallbackMatchesCurrent(signInID: signInID, flowID: flowID) else {
                finishIgnoredManagedOAuthCallbackIfEnded()
                return false
            }
            return true
        } catch {
            reportManagedOAuthCallbackStateReadErrorForUnknownSurface(error, generation: generation)
            return false
        }
    }

    private func managedOAuthCallbackMatchesCurrent(signInID: String?, flowID: String?) throws -> Bool {
        guard try secrets.value(for: .managedOAuthSignInID) == signInID else { return false }
        return try managedOAuthCallbackFlowMatches(flowID: flowID, resetCanceledWhenMissing: false)
    }

    private func managedOAuthCallbackFlowMatches(
        flowID: String?,
        resetCanceledWhenMissing: Bool
    ) throws -> Bool {
        let currentFlowID = try secrets.value(for: .managedOAuthFlowID)
        guard let flowID else { return currentFlowID == nil }
        if currentFlowID == nil, resetCanceledWhenMissing {
            _ = consumeCanceledManagedOAuthCallbackSurface()
            pendingManagedSignInMessageSurface = .shared
        }
        return currentFlowID == flowID
    }

    private func reportManagedOAuthCallbackStateReadError(
        _ error: Error,
        generation: UInt64,
        surface: TransientMessageSurface
    ) {
        reportManagedOAuthCallbackError(
            Self.callbackStateReadMessage(subject: "Sentwise sign-in state", error: error),
            generation: generation,
            surface: surface
        )
    }

    private func reportManagedOAuthCallbackStateReadErrorForUnknownSurface(
        _ error: Error,
        generation: UInt64
    ) {
        let message = Self.callbackStateReadMessage(subject: "Sentwise sign-in state", error: error)
        reportManagedOAuthCallbackError(message, generation: generation, surface: .shared)
        reportManagedOAuthCallbackError(message, generation: generation, surface: .settings)
    }

    private func reportManagedOAuthCallbackError(
        _ message: String,
        generation: UInt64,
        surface: TransientMessageSurface
    ) {
        let reported = reportManagedErrorIfCurrent(message, generation: generation, surface: surface)
        if reported || surface == .settings {
            if !reported {
                setManagedError(message, for: surface)
            }
            markSettingsManagedCallbackErrorPendingDisplay(for: surface)
        }
    }

    func persistManagedOAuthMessageSurfaceBestEffort(_ surface: TransientMessageSurface) {
        do {
            try secrets.set(surface.persistedValue, for: .managedOAuthMessageSurface)
        } catch {
            logger.error("Failed to persist managed OAuth message surface: \(error.localizedDescription)")
        }
    }

    func clearManagedOAuthMessageSurfaceBestEffort() {
        do {
            try secrets.remove(.managedOAuthMessageSurface)
        } catch {
            logger.error("Failed to clear managed OAuth message surface: \(error.localizedDescription)")
        }
    }

    func clearManagedOAuthFlowIDBestEffort() {
        do {
            try secrets.remove(.managedOAuthFlowID)
        } catch {
            logger.error("Failed to clear managed OAuth flow id: \(error.localizedDescription)")
        }
    }

    func persistCanceledManagedOAuthCallbackSurfaceBestEffort(_ surface: TransientMessageSurface) {
        do {
            try secrets.set(surface.persistedValue, for: .managedOAuthCanceledCallbackSurface)
        } catch {
            logger.error("Failed to persist canceled managed OAuth marker: \(error.localizedDescription)")
        }
    }

    func clearCanceledManagedOAuthCallbackSurfaceBestEffort() {
        do {
            try secrets.remove(.managedOAuthCanceledCallbackSurface)
        } catch {
            logger.error("Failed to clear canceled managed OAuth marker: \(error.localizedDescription)")
        }
    }

    private func currentManagedOAuthMessageSurface() -> TransientMessageSurface {
        Self.managedOAuthMessageSurface(secrets: secrets) ?? pendingManagedSignInMessageSurface
    }

    private func shouldHandleManagedOAuthCallback(flowID: String?) -> Bool {
        do {
            return try managedOAuthCallbackFlowMatches(flowID: flowID, resetCanceledWhenMissing: true)
        } catch {
            reportManagedOAuthCallbackStateReadErrorForUnknownSurface(
                error,
                generation: settingsTransientMessageGeneration
            )
            return false
        }
    }

    private func finishIgnoredManagedOAuthCallbackIfEnded() {
        if ((try? secrets.value(for: .managedOAuthSignInID)) ?? nil) == nil {
            _ = consumeCanceledManagedOAuthCallbackSurface()
            pendingManagedSignInMessageSurface = .shared
        }
    }

    private func discardIgnoredManagedOAuthSuccessIfEnded() async {
        do {
            guard try secrets.value(for: .managedOAuthFlowID) == nil else { return }
        } catch {
            reportManagedOAuthCallbackStateReadErrorForUnknownSurface(
                error,
                generation: settingsTransientMessageGeneration
            )
            return
        }
        do {
            try await managedAccount.signOut()
        } catch {
            logger.error("Failed to discard canceled managed OAuth session: \(error.localizedDescription)")
        }
        finishIgnoredManagedOAuthCallbackIfEnded()
        clearManagedOAuthMessageSurfaceBestEffort()
        pendingManagedSignInActivatesProvider = true
    }

    static func managedOAuthMessageSurface(secrets: SecretStore) -> TransientMessageSurface? {
        let value = (try? secrets.value(for: .managedOAuthMessageSurface)) ?? nil
        return value.flatMap(TransientMessageSurface.init(persistedValue:))
    }

    private func consumeCanceledManagedOAuthCallbackSurface() -> TransientMessageSurface? {
        let value = (try? secrets.value(for: .managedOAuthCanceledCallbackSurface)) ?? nil
        let surface = value.flatMap(TransientMessageSurface.init(persistedValue:))
        clearCanceledManagedOAuthCallbackSurfaceBestEffort()
        return surface
    }
}
