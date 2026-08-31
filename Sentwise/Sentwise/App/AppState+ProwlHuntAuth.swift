import Foundation

/// Deterministic, fully-offline completions of the managed-account and OpenRouter
/// sign-in flows for **Prowl hunt mode only** (item 70). These let accessibility
/// hunts drive the item-59 sign-in/provider surfaces end-to-end without any
/// network, browser hand-off, real key exchange, or Clerk/OpenRouter/Anthropic
/// call — everything stays in memory against `.invalid` fixtures.
///
/// Every method is strictly gated on `isHuntMode` (defaulting to
/// `ProwlHuntRuntime.current.isEnabled`) and no-ops outside hunt mode, so the
/// production sign-in paths (`AppState+ManagedOAuth`, `AppState+OpenRouter`,
/// `AppState+URLCallback`) are never affected. `isHuntMode` is injectable so unit
/// tests can exercise these without launching in a real hunt bundle.
extension AppState {

    /// The fixture account a hunt "signs in" as via the Google (browser) fake.
    /// `.invalid` (RFC 2606) never resolves, mirroring the mail fixture.
    static let huntFixtureGoogleEmail = "hunt.google@sentwise.invalid"

    /// Hunt-only: deterministically completes the Google browser sign-in that
    /// `startManagedGoogleSignIn` staged (`awaitingBrowser`), with no network and
    /// no real `sentwise://oauth-callback` round-trip. Mirrors the state the real
    /// `handleManagedOAuthCallback` reaches: managed becomes the active provider
    /// and the account is connected.
    func completeManagedGoogleSignInForHunt(isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled) {
        guard isHuntMode else { return }
        if pendingManagedSignInActivatesProvider, llmProviderKind != .managed { selectLLMProvider(.managed) }
        finalizeManagedSignIn(email: Self.huntFixtureGoogleEmail, accountID: "hunt-google")
    }

    /// Hunt-only: deterministically completes OpenRouter provisioning to a fake
    /// OpenAI-compatible provider, with no browser, no PKCE exchange, and no real
    /// key. Mirrors the state the real `handleOpenRouterCallback` reaches so the
    /// BYO card shows the OpenRouter (OpenAI-compatible) provider active.
    func completeOpenRouterProvisioningForHunt(isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled) {
        guard isHuntMode else { return }
        llmError = nil
        let fakeKey = "hunt-openrouter-fixture-key"
        // Store the fake key like the real callback so `refreshLLMConnectionStatus`
        // recomputes the provider as connected. In hunt mode (and tests) `secrets`
        // is an in-memory store, so nothing is written to the real Keychain.
        try? secrets.set(
            fakeKey,
            for: Self.llmAPIKeySecret(provider: .openAICompatible, baseURL: OpenRouterKeyProvisioner.apiBaseURL)
        )
        llmProviderKind = .openAICompatible
        llmBaseURL = OpenRouterKeyProvisioner.apiBaseURL
        llmAPIKey = fakeKey
        llmModel = Self.openRouterDefaultModel
        verifiedLLMModel = Self.openRouterDefaultModel
        isLLMConnected = true
        refreshLLMConnectionStatus()
        resetDraftPreviewForLLMChange()
        saveSettings()
    }
}
