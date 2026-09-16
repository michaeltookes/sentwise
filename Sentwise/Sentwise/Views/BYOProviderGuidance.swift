import SwiftUI

/// Parked 2026-09-16 (item 100): bring-your-own-provider views. BYOK/local providers
/// were removed from the UI and the product story; managed inference is the only
/// shipped path. Nothing reachable from the UI instantiates these views — they are
/// kept here, compiling, so the guided BYO path (item 59) can be revived without
/// rebuilding it. The underlying `AppState` actions (`selectLLMProvider`,
/// `testLLMConnection`, `disconnectLLM`, the OpenRouter provisioning flow) remain as
/// the parked seam. `ActiveProviderBadge`, `ConnectedBadge`, and `OnboardingError`
/// stay in the reachable managed/onboarding files.

/// One-sentence privacy upgrade statement for the BYO path.
struct ProviderPrivacyNote: View {
    var body: some View {
        Label(
            "With your own key, Sentwise's servers are never in the loop.",
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// "Get an API key" + a short numbered checklist + the honest billing/quality
/// notes for a given provider.
struct ProviderKeyGuidance: View {
    let provider: LLMProviderKind
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = provider.apiKeyCreationURL {
                Button("Get an API key") { openURL(url) }
                    .accessibilityIdentifier("getAPIKeyButton")
            }
            ForEach(Array(provider.keySetupSteps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider.mentionsProviderBilling {
                Label("The provider will ask for payment details.", systemImage: "creditcard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = provider.localModelQualityNote {
                Label(note, systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The featured OpenRouter one-click card: PKCE key provisioning with no manual
/// copy-paste. Disabled in Prowl hunt mode.
struct OpenRouterProvisionCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    let messageSurface: AppState.TransientMessageSurface

    init(messageSurface: AppState.TransientMessageSurface = .shared) {
        self.messageSurface = messageSurface
    }

    private var isHuntMode: Bool { ProwlHuntRuntime.current.isEnabled }

    /// Whether OpenRouter (the OpenAI-compatible provider pointed at OpenRouter's
    /// base URL) is the connected, active provider — i.e. provisioning succeeded.
    private var isOpenRouterConnected: Bool {
        appState.llmProviderKind == .openAICompatible
            && appState.llmBaseURL == OpenRouterKeyProvisioner.apiBaseURL
            && appState.isLLMConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(.tint)
                Text("OpenRouter — one-click setup").font(.callout).bold()
                Spacer()
                if isOpenRouterConnected {
                    ConnectedBadge(text: "Connected")
                        .accessibilityIdentifier("openRouterConnectedBadge")
                }
            }
            Text("Provisions a key with no copy-paste — one account reaches every major model.")
                .font(.caption).foregroundStyle(.secondary)
            if !isOpenRouterConnected {
                if appState.isOpenRouterProvisioning {
                    Label("Finish connecting in your browser.", systemImage: "safari")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") {
                        appState.cancelOpenRouterProvisioning(messageSurface: messageSurface)
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("openRouterCancelButton")
                } else if appState.hasStoredOpenRouterCredential {
                    Button("Use saved OpenRouter key") {
                        appState.activateStoredOpenRouterProvider(messageSurface: messageSurface)
                    }
                    .disabled(appState.isTestingLLM)
                    .accessibilityIdentifier("openRouterUseSavedButton")
                } else {
                    Button {
                        // Hunt mode: complete deterministically offline — no browser,
                        // no PKCE exchange, no real key. Production opens the browser.
                        if isHuntMode {
                            appState.completeOpenRouterProvisioningForHunt(messageSurface: messageSurface)
                        } else if let url = appState.beginOpenRouterProvisioning(messageSurface: messageSurface) {
                            openURL(url)
                        }
                    } label: {
                        if appState.isTestingLLM {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Connect OpenRouter")
                        }
                    }
                    .disabled(appState.isTestingLLM || appState.isOpenRouterProvisioning)
                    .accessibilityIdentifier("openRouterConnectButton")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}

/// BYO-provider errors live with the shared provider controls so Settings and
/// onboarding surface failed tests, invalid URLs, Keychain failures, and callback
/// failures consistently.
struct BYOProviderErrorMessage: View {
    @EnvironmentObject var appState: AppState
    let messageSurface: AppState.TransientMessageSurface
    let settingsDisplayTab: SettingsTab?

    init(
        messageSurface: AppState.TransientMessageSurface = .shared,
        settingsDisplayTab: SettingsTab? = nil
    ) {
        self.messageSurface = messageSurface
        self.settingsDisplayTab = settingsDisplayTab
    }

    var body: some View {
        if let error = appState.llmError(for: messageSurface) {
            OnboardingError(message: error)
                .onAppear {
                    markCallbackErrorDisplayed()
                }
                .onChange(of: error) { _, _ in
                    markCallbackErrorDisplayed()
                }
        }
    }

    private func markCallbackErrorDisplayed() {
        guard let settingsDisplayTab else { return }
        appState.markSettingsLLMCallbackErrorDisplayed(
            for: messageSurface,
            visibleIn: settingsDisplayTab
        )
    }
}

/// The guided bring-your-own-provider controls (item 59): featured OpenRouter
/// one-click, a provider picker with per-provider key guidance, model/base-URL/key
/// + Test Connection, the connected state, and the privacy note. Managed is
/// excluded from the picker — it lives in its own card above.
struct BYOProviderControls: View {
    @EnvironmentObject var appState: AppState
    let messageSurface: AppState.TransientMessageSurface
    let settingsDisplayTab: SettingsTab?

    /// The provider highlighted in the picker. Staged locally so opening the
    /// picker doesn't immediately switch the active provider; "Use this provider"
    /// makes the switch. Synced to the active provider when BYO is live.
    @State private var stagedProvider: LLMProviderKind = .anthropic

    init(
        messageSurface: AppState.TransientMessageSurface = .shared,
        settingsDisplayTab: SettingsTab? = nil
    ) {
        self.messageSurface = messageSurface
        self.settingsDisplayTab = settingsDisplayTab
    }

    private var byoProviders: [LLMProviderKind] {
        LLMProviderKind.allCases.filter { $0 != .managed }
    }

    /// Whether the staged provider is the one currently drafting.
    private var isStagedProviderActive: Bool {
        appState.llmProviderKind == stagedProvider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OpenRouterProvisionCard(messageSurface: messageSurface)

            Divider()
                .padding(.vertical, 8)

            HStack {
                Picker("Provider", selection: $stagedProvider) {
                    ForEach(byoProviders) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .accessibilityIdentifier("byoProviderPicker")
                Spacer()
                if isStagedProviderActive && appState.isBYOProviderActive {
                    ActiveProviderBadge()
                }
            }

            if isStagedProviderActive {
                activeProviderConfig
            } else {
                Button("Use this provider") {
                    appState.selectLLMProvider(stagedProvider, messageSurface: messageSurface)
                }
                    .accessibilityIdentifier("useThisProviderButton")
                ProviderKeyGuidance(provider: stagedProvider)
            }

            BYOProviderErrorMessage(messageSurface: messageSurface, settingsDisplayTab: settingsDisplayTab)
            ProviderPrivacyNote()
        }
        .onAppear {
            syncStagedProviderWithActiveProvider()
        }
        .onChange(of: appState.llmProviderKind) { _, _ in
            syncStagedProviderWithActiveProvider()
        }
    }

    /// Model / base URL / key / Test Connection (or the connected state) for the
    /// active BYO provider.
    @ViewBuilder
    private var activeProviderConfig: some View {
        TextField("Model", text: modelBinding, prompt: Text(appState.llmProviderKind.defaultModel))
            .textFieldStyle(.roundedBorder)

        if appState.llmProviderKind.supportsCustomBaseURL {
            TextField(
                "Base URL (optional)",
                text: baseURLBinding,
                prompt: Text(appState.llmProviderKind.baseURLPlaceholder ?? "")
            )
            .textFieldStyle(.roundedBorder)
        }

        if appState.isLLMConnected {
            ConnectedBadge(text: "Connected")
            Text("Saved to your Keychain.").font(.caption).foregroundStyle(.secondary)
            Button("Disconnect", role: .destructive) {
                appState.disconnectLLM(provider: appState.llmProviderKind, messageSurface: messageSurface)
            }
        } else {
            ProviderKeyGuidance(provider: appState.llmProviderKind)
            SecureField(apiKeyFieldTitle, text: $appState.llmAPIKey)
                .textFieldStyle(.roundedBorder)
            if !appState.llmProviderKind.requiresAPIKey {
                Text("Optional — leave blank for Ollama or unauthenticated local runtimes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await appState.testLLMConnection(messageSurface: messageSurface) }
            } label: {
                if appState.isTestingLLM {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Test Connection")
                }
            }
            .disabled(appState.isTestingLLM)
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { appState.llmModel },
            set: {
                appState.llmModel = $0
                appState.refreshLLMConnectionStatus()
            }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { appState.llmBaseURL },
            set: { appState.updateLLMBaseURLFromUser($0, messageSurface: messageSurface) }
        )
    }

    private var apiKeyFieldTitle: String {
        appState.llmProviderKind.requiresAPIKey ? "API key" : "API key (optional)"
    }

    private func syncStagedProviderWithActiveProvider() {
        if appState.isBYOProviderActive {
            stagedProvider = appState.llmProviderKind
        }
    }
}
