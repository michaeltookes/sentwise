import Foundation

/// LLM-provider actions on `AppState`. Kept in a separate file so `AppState`
/// stays within the file/type length limits.
extension AppState {

    /// Whether managed inference (Sentwise AI) is the provider currently drafting.
    /// The two provider cards key their "Active" badge off this so exactly one is
    /// ever shown live at a time (item 59).
    var isManagedProviderActive: Bool { llmProviderKind == .managed }

    /// Whether a bring-your-own provider (anything but managed) is the one
    /// currently drafting — the exact inverse of `isManagedProviderActive`.
    var isBYOProviderActive: Bool { llmProviderKind != .managed }

    /// The model to use: the user's choice, or the provider default if blank.
    var resolvedLLMModel: String {
        resolvedLLMModel(for: llmModel)
    }

    func resolvedLLMModel(for model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? llmProviderKind.defaultModel : trimmed
    }

    /// The base URL to pass to the LLM layer for the current provider: the
    /// user's override when the provider is endpoint-configurable and a value is
    /// set, otherwise `nil` (provider default). Providers that don't support a
    /// custom endpoint always resolve to `nil`, so a stale value left over from
    /// another provider is ignored.
    var currentLLMBaseURL: String? {
        guard llmProviderKind.supportsCustomBaseURL else { return nil }
        let trimmed = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var currentLLMAPIKeySecret: SecretKey {
        Self.llmAPIKeySecret(provider: llmProviderKind, baseURL: currentLLMBaseURL)
    }

    static func llmAPIKeySecret(provider: LLMProviderKind, baseURL: String?) -> SecretKey {
        guard provider == .openAICompatible, isOpenRouterBaseURL(baseURL) else {
            return provider.apiKeySecret
        }
        return .openRouterAPIKey
    }

    static func storedLLMAPIKey(
        provider: LLMProviderKind,
        baseURL: String?,
        secrets: SecretStore
    ) -> String {
        let primarySecret = llmAPIKeySecret(provider: provider, baseURL: baseURL)
        if let primary = ((try? secrets.value(for: primarySecret)) ?? nil), !primary.isEmpty {
            return primary
        }
        guard primarySecret == .openRouterAPIKey,
              let legacy = ((try? secrets.value(for: provider.apiKeySecret)) ?? nil),
              !legacy.isEmpty else {
            return ""
        }
        do {
            try secrets.set(legacy, for: primarySecret)
            try? secrets.remove(provider.apiKeySecret)
        } catch {
            // Keep using the legacy key as a read fallback if migration fails.
        }
        return legacy
    }

    /// Applies a user edit to the custom base URL. Because the endpoint is part
    /// of what a connection test verifies, editing it clears the verified state
    /// so the user must re-test before the provider counts as connected.
    func updateLLMBaseURLFromUser(_ newValue: String) {
        guard newValue != llmBaseURL else { return }
        let previousOrigin = currentLLMEndpointOrigin
        let previousAPIKeySecret = currentLLMAPIKeySecret
        llmBaseURL = newValue
        let shouldClearKey = llmProviderKind.supportsCustomBaseURL
            && shouldClearLLMAPIKeyForEndpointChange(from: previousOrigin, to: currentLLMEndpointOrigin)
        llmError = nil
        if shouldClearKey {
            clearLLMAPIKeyForEndpointChange(secret: previousAPIKeySecret)
        }
        verifiedLLMModel = ""
        refreshLLMConnectionStatus()
        resetDraftPreviewForLLMChange()
        saveSettings()
    }

    /// Recomputes whether the current credential is verified for the currently
    /// selected provider/model pair. Key-optional providers (local runtimes) need
    /// no stored key — a matching verified model alone counts as connected.
    func refreshLLMConnectionStatus(llmModel model: String? = nil) {
        // Managed inference is "connected" when the account is signed in and the
        // (default) model is verified — there is no API key to check.
        if llmProviderKind == .managed {
            isLLMConnected = isManagedSignedIn
                && resolvedLLMModel(for: model ?? llmModel) == verifiedLLMModel
            return
        }
        let hasCredential = !llmProviderKind.requiresAPIKey
            || !Self.storedLLMAPIKey(
                provider: llmProviderKind,
                baseURL: currentLLMBaseURL,
                secrets: secrets
            ).isEmpty
        isLLMConnected = hasCredential
            && resolvedLLMModel(for: model ?? llmModel) == verifiedLLMModel
    }

    /// Switches the selected provider, reloading its stored key and status.
    /// The model field is cleared so the new provider starts from its default
    /// instead of reusing another provider's model id. The custom base URL is
    /// shared in settings, so clear it on provider changes to avoid sending the
    /// new provider's requests to the previous provider's endpoint.
    func selectLLMProvider(_ provider: LLMProviderKind) {
        guard provider != llmProviderKind else { return }
        let selectedBaseURL = restoredBaseURLOnProviderSelection(provider)
        llmProviderKind = provider
        llmBaseURL = selectedBaseURL
        llmAPIKey = Self.storedLLMAPIKey(
            provider: provider,
            baseURL: selectedBaseURL.isEmpty ? nil : selectedBaseURL,
            secrets: secrets
        )
        llmModel = restoredModelOnProviderSelection(provider, baseURL: selectedBaseURL, apiKey: llmAPIKey)
        verifiedLLMModel = restoredVerifiedModelOnProviderSelection(
            provider,
            baseURL: selectedBaseURL,
            apiKey: llmAPIKey
        )
        refreshLLMConnectionStatus()
        resetDraftPreviewForLLMChange()
        llmError = nil
        saveSettings()
    }

    /// Verifies the API key with a live test call and, on success, stores it.
    func testLLMConnection() async {
        llmError = nil

        let key = llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if llmProviderKind.requiresAPIKey {
            guard !key.isEmpty else {
                llmError = "Enter an API key first."
                return
            }
        }

        isTestingLLM = true
        defer { isTestingLLM = false }

        let testedProvider = llmProviderKind
        let testedModel = resolvedLLMModel
        let testedBaseURL = currentLLMBaseURL
        let testedAPIKeySecret = currentLLMAPIKeySecret

        do {
            try await llm.testConnection(
                provider: testedProvider,
                apiKey: key,
                model: testedModel,
                baseURL: testedBaseURL
            )
        } catch {
            await reconcileManagedAccountState(after: error, provider: testedProvider)
            llmError = Self.llmMessage(for: error)
            return
        }

        guard llmProviderKind == testedProvider,
              resolvedLLMModel == testedModel,
              currentLLMBaseURL == testedBaseURL,
              llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) == key else {
            llmError = "Connection settings changed. Test again."
            refreshLLMConnectionStatus()
            return
        }

        if key.isEmpty {
            do {
                try secrets.remove(testedAPIKeySecret)
            } catch {
                llmError = Self.keychainLLMMessage(action: "remove", error: error)
                return
            }
        } else {
            do {
                try secrets.set(key, for: testedAPIKeySecret)
            } catch {
                llmError = Self.keychainLLMMessage(action: "save", error: error)
                return
            }
        }

        verifiedLLMModel = testedModel
        resetDraftPreviewForLLMChange()
        saveSettings()
        isLLMConnected = true
        // Now that drafting is possible, catch up any transcript that arrived in
        // the watched folder while the provider was disconnected (item 51).
        startTranscriptFolderWatchingIfEnabled()
    }

    /// Disconnects a BYO provider by clearing its stored API key. Defaults to the
    /// active provider; the Settings/onboarding BYO card passes the provider it is
    /// displaying so Disconnect works even while managed inference is active.
    func disconnectLLM(provider: LLMProviderKind? = nil) {
        llmError = nil
        let target = provider ?? llmProviderKind
        // Managed inference has no stored API key; disconnecting it means signing
        // out of the account, which is a distinct, explicit action in the UI.
        guard target != .managed else { return }
        let targetSecret = target == llmProviderKind ? currentLLMAPIKeySecret : target.apiKeySecret
        do {
            try secrets.remove(targetSecret)
        } catch {
            llmError = Self.keychainLLMMessage(action: "remove", error: error)
            return
        }
        // Clearing a key for a provider that isn't active leaves the active
        // (managed) connection untouched.
        guard target == llmProviderKind else { return }
        llmAPIKey = ""
        verifiedLLMModel = ""
        refreshLLMConnectionStatus()
        resetDraftPreviewForLLMChange()
        saveSettings()
    }

    // MARK: - Error messages

    static func llmMessage(for error: Error) -> String {
        switch error {
        case LLMError.missingAPIKey:
            return "Enter an API key first."
        case LLMError.transport(let detail):
            return "Couldn't reach the provider. (\(detail))"
        case LLMError.http(let status, let message):
            return "The provider rejected the request (HTTP \(status)). \(message)"
        case LLMError.invalidResponse(let detail):
            return "Unexpected response from the provider. (\(detail))"
        case LLMError.invalidBaseURL(let value):
            return "Invalid base URL: \(value). Enter a full http(s) URL, e.g. https://api.openai.com/v1."
        case LLMError.managedNotSignedIn:
            return "Sign in to Sentwise AI first (Settings → AI)."
        case LLMError.managedTrialExpired(let message):
            return message
        case KeychainError.unexpectedStatus(let status):
            return "Keychain returned status \(status)."
        case KeychainError.dataEncodingFailed:
            return "Keychain could not encode the API key."
        default:
            return error.localizedDescription
        }
    }

    static func keychainLLMMessage(action: String, error: Error) -> String {
        "Couldn't \(action) the API key in Keychain. \(llmMessage(for: error))"
    }

    private var currentLLMEndpointOrigin: String? {
        let defaultEndpoint = llmProviderKind.defaultOpenAICompatibleEndpoint
            ?? OpenAICompatibleClient.defaultEndpoint
        guard let endpoint = try? OpenAICompatibleClient.resolveEndpoint(
                baseURL: currentLLMBaseURL,
                defaultEndpoint: defaultEndpoint
              ),
              let scheme = endpoint.scheme?.lowercased(),
              let host = endpoint.host?.lowercased() else {
            return nil
        }
        let port = endpoint.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func shouldClearLLMAPIKeyForEndpointChange(from oldOrigin: String?, to newOrigin: String?) -> Bool {
        oldOrigin != newOrigin || oldOrigin == nil || newOrigin == nil
    }

    private func clearLLMAPIKeyForEndpointChange(secret: SecretKey) {
        llmAPIKey = ""
        do {
            try secrets.remove(secret)
        } catch {
            llmError = Self.keychainLLMMessage(action: "remove", error: error)
        }
    }

    private func restoredBaseURLOnProviderSelection(_ provider: LLMProviderKind) -> String {
        guard provider == .openAICompatible,
              !secrets.hasValue(for: provider.apiKeySecret),
              secrets.hasValue(for: .openRouterAPIKey) else {
            return ""
        }
        return OpenRouterKeyProvisioner.apiBaseURL
    }

    private func restoredModelOnProviderSelection(
        _ provider: LLMProviderKind,
        baseURL: String,
        apiKey: String
    ) -> String {
        guard provider == .openAICompatible,
              !apiKey.isEmpty,
              Self.isOpenRouterBaseURL(baseURL) else {
            return ""
        }
        return Self.openRouterDefaultModel
    }

    private func restoredVerifiedModelOnProviderSelection(
        _ provider: LLMProviderKind,
        baseURL: String,
        apiKey: String
    ) -> String {
        if provider == .managed && isManagedSignedIn {
            return provider.defaultModel
        }
        return restoredModelOnProviderSelection(provider, baseURL: baseURL, apiKey: apiKey)
    }

    private static func isOpenRouterBaseURL(_ baseURL: String?) -> Bool {
        guard let endpoint = try? OpenAICompatibleClient.resolveEndpoint(
            baseURL: baseURL,
            defaultEndpoint: OpenAICompatibleClient.defaultEndpoint
        ) else {
            return false
        }
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.host?.lowercased() == "openrouter.ai" else {
            return false
        }
        return endpoint.path == "/api/v1/chat/completions"
    }
}
