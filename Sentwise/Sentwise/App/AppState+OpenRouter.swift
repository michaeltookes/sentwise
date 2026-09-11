import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "OpenRouter")

/// OpenRouter one-click BYO key provisioning (item 59). Generates a PKCE pair,
/// sends the user to OpenRouter's authorization page, and on the
/// `sentwise://openrouter-callback` redirect exchanges the code for a real key,
/// storing it as the OpenAI-compatible provider pointed at OpenRouter's base URL.
extension AppState {

    /// The custom-scheme URL OpenRouter redirects back to. Registered in
    /// `Info.plist`; passed to OpenRouter as `callback_url`.
    /// OpenRouter redirects the browser here (Worker landing page → `sentwise://openrouter-callback`).
    static var openRouterCallbackURL: String {
        ManagedInference.baseURL.appendingPathComponent("openrouter/callback").absoluteString
    }
    /// A sensible default model for a freshly provisioned OpenRouter key. The user
    /// can change it; OpenRouter namespaces model ids by publisher.
    static let openRouterDefaultModel = "openai/gpt-4o-mini"

    /// Begins OpenRouter provisioning: mints a PKCE pair, stores the verifier, and
    /// returns the authorization URL to open in the browser. Returns `nil` (and
    /// sets the surface-specific LLM error) in hunt mode or if the verifier can't
    /// be stored. Disabled in Prowl hunt mode so hunts never reach the network.
    func beginOpenRouterProvisioning(messageSurface: TransientMessageSurface = .shared) -> URL? {
        setLLMError(nil, for: messageSurface)
        guard !ProwlHuntRuntime.current.isEnabled else {
            setLLMError("OpenRouter sign-in is disabled during Prowl hunts.", for: messageSurface)
            return nil
        }
        if isOpenRouterProvisioning || secrets.hasValue(for: .openRouterPKCEVerifier) {
            let pendingSurface = Self.openRouterProvisioningMessageSurface(secrets: secrets) ?? messageSurface
            isOpenRouterProvisioning = true
            pendingOpenRouterProvisioningMessageSurface = pendingSurface
            persistOpenRouterProvisioningMessageSurfaceBestEffort(pendingSurface)
            setLLMError("Finish OpenRouter setup in your browser, or cancel it and try again.", for: pendingSurface)
            return nil
        }
        let codes = PKCEGenerator.generate()
        clearCanceledOpenRouterCallbackSurfaceBestEffort()
        do {
            try secrets.set(codes.verifier, for: .openRouterPKCEVerifier)
            try secrets.set(messageSurface.persistedValue, for: .openRouterPKCEMessageSurface)
        } catch {
            try? secrets.remove(.openRouterPKCEVerifier)
            try? secrets.remove(.openRouterPKCEMessageSurface)
            setLLMError(Self.keychainLLMMessage(action: "save", error: error), for: messageSurface)
            return nil
        }
        isOpenRouterProvisioning = true
        pendingOpenRouterProvisioningMessageSurface = messageSurface
        return OpenRouterKeyProvisioner().authorizationURL(
            callbackURL: Self.openRouterCallbackURL,
            challenge: codes.challenge
        )
    }

    /// Convenience for the UI: begin provisioning and open the URL in the browser.
    func startOpenRouterProvisioning(
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) },
        messageSurface: TransientMessageSurface = .shared
    ) {
        guard let url = beginOpenRouterProvisioning(messageSurface: messageSurface) else { return }
        openURL(url)
    }

    /// Cancels the browser-based provisioning flow so the next Connect click can
    /// mint a fresh verifier instead of invalidating an in-flight browser tab.
    func cancelOpenRouterProvisioning(messageSurface: TransientMessageSurface = .shared) {
        setLLMError(nil, for: messageSurface)
        isOpenRouterProvisioning = false
        pendingOpenRouterProvisioningMessageSurface = messageSurface
        do {
            try secrets.remove(.openRouterPKCEVerifier)
            try secrets.remove(.openRouterPKCEMessageSurface)
            try secrets.set(messageSurface.persistedValue, for: .openRouterCanceledCallbackSurface)
        } catch {
            setLLMError(Self.keychainLLMMessage(action: "remove", error: error), for: messageSurface)
        }
    }

    /// Whether a previously provisioned/tested OpenRouter key is available. The
    /// key lives apart from the generic OpenAI-compatible slot so both credentials
    /// can coexist without overwriting each other.
    var hasStoredOpenRouterCredential: Bool {
        secrets.hasValue(for: .openRouterAPIKey)
    }

    func restoreOpenRouterProvisioningLaunchState() {
        isOpenRouterProvisioning = secrets.hasValue(for: .openRouterPKCEVerifier)
        pendingOpenRouterProvisioningMessageSurface = currentOpenRouterProvisioningMessageSurface()
    }

    /// Reactivates the stored OpenRouter credential without starting another browser
    /// authorization. This keeps a saved OpenRouter key reachable even when a generic
    /// OpenAI-compatible key is also present.
    func activateStoredOpenRouterProvider(messageSurface: TransientMessageSurface = .shared) {
        setLLMError(nil, for: messageSurface)
        let key = Self.storedLLMAPIKey(
            provider: .openAICompatible,
            baseURL: OpenRouterKeyProvisioner.apiBaseURL,
            secrets: secrets
        )
        guard !key.isEmpty else {
            setLLMError("Connect OpenRouter first.", for: messageSurface)
            refreshLLMConnectionStatus()
            return
        }

        llmProviderKind = .openAICompatible
        llmBaseURL = OpenRouterKeyProvisioner.apiBaseURL
        llmAPIKey = key
        llmModel = Self.openRouterDefaultModel
        verifiedLLMModel = Self.openRouterDefaultModel
        refreshLLMConnectionStatus()
        resetDraftPreviewForLLMChange()
        saveSettings()
        startTranscriptFolderWatchingIfEnabled()
        resumeInboxWatchingAfterProviderRecoveryIfNeeded()
    }

    /// Completes provisioning from the redirect `code`: exchanges it (with the
    /// stored PKCE verifier) for an API key and activates the OpenAI-compatible
    /// provider with OpenRouter's base URL. The provisioner is injectable so the
    /// exchange is testable without the network.
    func handleOpenRouterCallback(
        code: String,
        provisioner: OpenRouterKeyProvisioner = OpenRouterKeyProvisioner()
    ) async {
        guard let verifier = (try? secrets.value(for: .openRouterPKCEVerifier)) ?? nil, !verifier.isEmpty else {
            handleMissingOpenRouterVerifierCallback()
            return
        }
        let messageSurface = currentOpenRouterProvisioningMessageSurface()
        setLLMError(nil, for: messageSurface)
        let settingsMessageGeneration = settingsTransientMessageGeneration

        isTestingLLM = true
        defer { isTestingLLM = false }

        let key: String
        do {
            key = try await provisioner.exchangeCodeForKey(code: code, codeVerifier: verifier)
        } catch {
            isOpenRouterProvisioning = false
            reportOpenRouterCallbackError(
                Self.llmMessage(for: error),
                generation: settingsMessageGeneration,
                surface: messageSurface
            )
            return
        }
        guard isCurrentOpenRouterProvisioning(verifier: verifier) else {
            if ((try? secrets.value(for: .openRouterPKCEVerifier)) ?? nil) == nil {
                _ = consumeCanceledOpenRouterCallbackSurface()
                pendingOpenRouterProvisioningMessageSurface = .shared
            }
            return
        }

        do {
            try secrets.set(
                key,
                for: Self.llmAPIKeySecret(
                    provider: .openAICompatible,
                    baseURL: OpenRouterKeyProvisioner.apiBaseURL
                )
            )
        } catch {
            isOpenRouterProvisioning = false
            reportOpenRouterCallbackError(
                Self.keychainLLMMessage(action: "save", error: error),
                generation: settingsMessageGeneration,
                surface: messageSurface
            )
            return
        }
        try? secrets.remove(.openRouterPKCEVerifier)
        try? secrets.remove(.openRouterPKCEMessageSurface)
        clearCanceledOpenRouterCallbackSurfaceBestEffort()
        isOpenRouterProvisioning = false
        pendingOpenRouterProvisioningMessageSurface = .shared

        activateProvisionedOpenRouterKey(key)
    }

    private func isCurrentOpenRouterProvisioning(verifier: String) -> Bool {
        ((try? secrets.value(for: .openRouterPKCEVerifier)) ?? nil) == verifier
    }

    private func handleMissingOpenRouterVerifierCallback() {
        isOpenRouterProvisioning = false
        if consumeCanceledOpenRouterCallbackSurface() != nil {
            pendingOpenRouterProvisioningMessageSurface = .shared
            return
        }
        let messageSurface = currentOpenRouterProvisioningMessageSurface()
        pendingOpenRouterProvisioningMessageSurface = .shared
        reportOpenRouterCallbackError(
            "OpenRouter sign-in didn't start on this Mac. Try connecting again.",
            generation: settingsTransientMessageGeneration,
            surface: messageSurface
        )
    }

    private func reportOpenRouterCallbackError(
        _ message: String,
        generation: UInt64,
        surface: TransientMessageSurface
    ) {
        let reported = reportLLMErrorIfCurrent(message, generation: generation, surface: surface)
        if reported || surface == .settings {
            if !reported {
                setLLMError(message, for: surface)
            }
            markSettingsLLMCallbackErrorPendingDisplay(for: surface)
        }
    }

    private func activateProvisionedOpenRouterKey(_ key: String) {
        llmProviderKind = .openAICompatible
        llmBaseURL = OpenRouterKeyProvisioner.apiBaseURL
        llmAPIKey = key
        llmModel = Self.openRouterDefaultModel
        verifiedLLMModel = Self.openRouterDefaultModel
        isLLMConnected = true
        refreshLLMConnectionStatus()
        resetDraftPreviewForLLMChange()
        saveSettings()
        startTranscriptFolderWatchingIfEnabled()
        resumeInboxWatchingAfterProviderRecoveryIfNeeded()
        logger.info("OpenRouter key provisioned; OpenAI-compatible provider activated")
    }

    private func currentOpenRouterProvisioningMessageSurface() -> TransientMessageSurface {
        Self.openRouterProvisioningMessageSurface(secrets: secrets) ?? pendingOpenRouterProvisioningMessageSurface
    }

    static func openRouterProvisioningMessageSurface(secrets: SecretStore) -> TransientMessageSurface? {
        let value = (try? secrets.value(for: .openRouterPKCEMessageSurface)) ?? nil
        return value.flatMap(TransientMessageSurface.init(persistedValue:))
    }

    private func persistOpenRouterProvisioningMessageSurfaceBestEffort(_ surface: TransientMessageSurface) {
        do {
            try secrets.set(surface.persistedValue, for: .openRouterPKCEMessageSurface)
        } catch {
            logger.error("Failed to persist OpenRouter message surface: \(error.localizedDescription)")
        }
    }

    private func consumeCanceledOpenRouterCallbackSurface() -> TransientMessageSurface? {
        let value = (try? secrets.value(for: .openRouterCanceledCallbackSurface)) ?? nil
        let surface = value.flatMap(TransientMessageSurface.init(persistedValue:))
        clearCanceledOpenRouterCallbackSurfaceBestEffort()
        return surface
    }

    private func clearCanceledOpenRouterCallbackSurfaceBestEffort() {
        do {
            try secrets.remove(.openRouterCanceledCallbackSurface)
        } catch {
            logger.error("Failed to clear canceled OpenRouter callback marker: \(error.localizedDescription)")
        }
    }
}
