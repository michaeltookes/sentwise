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
    /// sets `llmError`) in hunt mode or if the verifier can't be stored. Disabled
    /// in Prowl hunt mode so hunts never reach the network.
    func beginOpenRouterProvisioning() -> URL? {
        llmError = nil
        guard !ProwlHuntRuntime.current.isEnabled else {
            llmError = "OpenRouter sign-in is disabled during Prowl hunts."
            return nil
        }
        if isOpenRouterProvisioning || secrets.hasValue(for: .openRouterPKCEVerifier) {
            isOpenRouterProvisioning = true
            llmError = "Finish OpenRouter setup in your browser, or cancel it and try again."
            return nil
        }
        let codes = PKCEGenerator.generate()
        do {
            try secrets.set(codes.verifier, for: .openRouterPKCEVerifier)
        } catch {
            llmError = Self.keychainLLMMessage(action: "save", error: error)
            return nil
        }
        isOpenRouterProvisioning = true
        return OpenRouterKeyProvisioner().authorizationURL(
            callbackURL: Self.openRouterCallbackURL,
            challenge: codes.challenge
        )
    }

    /// Convenience for the UI: begin provisioning and open the URL in the browser.
    func startOpenRouterProvisioning(openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        guard let url = beginOpenRouterProvisioning() else { return }
        openURL(url)
    }

    /// Cancels the browser-based provisioning flow so the next Connect click can
    /// mint a fresh verifier instead of invalidating an in-flight browser tab.
    func cancelOpenRouterProvisioning() {
        llmError = nil
        isOpenRouterProvisioning = false
        do {
            try secrets.remove(.openRouterPKCEVerifier)
        } catch {
            llmError = Self.keychainLLMMessage(action: "remove", error: error)
        }
    }

    /// Whether a previously provisioned/tested OpenRouter key is available. The
    /// key lives apart from the generic OpenAI-compatible slot so both credentials
    /// can coexist without overwriting each other.
    var hasStoredOpenRouterCredential: Bool {
        secrets.hasValue(for: .openRouterAPIKey)
    }

    /// Reactivates the stored OpenRouter credential without starting another browser
    /// authorization. This keeps a saved OpenRouter key reachable even when a generic
    /// OpenAI-compatible key is also present.
    func activateStoredOpenRouterProvider() {
        llmError = nil
        let key = Self.storedLLMAPIKey(
            provider: .openAICompatible,
            baseURL: OpenRouterKeyProvisioner.apiBaseURL,
            secrets: secrets
        )
        guard !key.isEmpty else {
            llmError = "Connect OpenRouter first."
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
    }

    /// Completes provisioning from the redirect `code`: exchanges it (with the
    /// stored PKCE verifier) for an API key and activates the OpenAI-compatible
    /// provider with OpenRouter's base URL. The provisioner is injectable so the
    /// exchange is testable without the network.
    func handleOpenRouterCallback(
        code: String,
        provisioner: OpenRouterKeyProvisioner = OpenRouterKeyProvisioner()
    ) async {
        llmError = nil
        guard let verifier = (try? secrets.value(for: .openRouterPKCEVerifier)) ?? nil, !verifier.isEmpty else {
            isOpenRouterProvisioning = false
            llmError = "OpenRouter sign-in didn't start on this Mac. Try connecting again."
            return
        }

        isTestingLLM = true
        defer { isTestingLLM = false }

        let key: String
        do {
            key = try await provisioner.exchangeCodeForKey(code: code, codeVerifier: verifier)
        } catch {
            isOpenRouterProvisioning = false
            llmError = Self.llmMessage(for: error)
            return
        }
        guard isCurrentOpenRouterProvisioning(verifier: verifier) else {
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
            llmError = Self.keychainLLMMessage(action: "save", error: error)
            return
        }
        try? secrets.remove(.openRouterPKCEVerifier)
        isOpenRouterProvisioning = false

        // Activate the OpenAI-compatible provider pointed at OpenRouter.
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
        logger.info("OpenRouter key provisioned; OpenAI-compatible provider activated")
    }

    private func isCurrentOpenRouterProvisioning(verifier: String) -> Bool {
        ((try? secrets.value(for: .openRouterPKCEVerifier)) ?? nil) == verifier
    }
}
