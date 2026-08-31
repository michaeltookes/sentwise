import SwiftUI

/// Shared AI-provider controls used by both onboarding and Settings (items 56a,
/// 59): the managed-inference sign-in card and the guided bring-your-own-provider
/// controls. Extracted from `OnboardingView` to keep that file within length limits.

/// The primary, pre-selected managed-inference option: sign in and draft, no key.
struct ManagedInferenceCard: View {
    @EnvironmentObject var appState: AppState

    private var isActive: Bool { appState.isManagedProviderActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Sentwise AI — included with your subscription").font(.callout).bold()
                Spacer()
                if isActive { ActiveProviderBadge() }
            }
            Text("Nothing to set up — no API key, no billing beyond Sentwise. 14-day free trial.")
                .font(.caption).foregroundStyle(.secondary)

            if !isActive {
                Button("Use Sentwise AI") { appState.selectLLMProvider(.managed) }
                    .accessibilityIdentifier("useManagedInference")
            } else if appState.isManagedSignedIn {
                ConnectedBadge(text: "Connected as \(appState.managedAccountEmail)")
                Button("Sign out") { Task { await appState.signOutManaged() } }
                    .disabled(appState.isManagedBusy)
                    .accessibilityIdentifier("managedSignOutButton")
            } else {
                Text("Sign in or create your account")
                    .font(.caption).foregroundStyle(.secondary)
                ManagedSignInControls()
            }
            ManagedAccountErrorMessage()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

/// Managed-account errors live at the enclosing provider level so sign-in and
/// sign-out failures remain visible in both signed-in and signed-out states.
struct ManagedAccountErrorMessage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let error = appState.managedError {
            OnboardingError(message: error)
        }
    }
}

/// BYO-provider errors live with the shared provider controls so Settings and
/// onboarding surface failed tests, invalid URLs, Keychain failures, and callback
/// failures consistently.
struct BYOProviderErrorMessage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let error = appState.llmError {
            OnboardingError(message: error)
        }
    }
}

/// Sign-in controls for the managed account: one-click Google alongside the
/// email-code flow. First-time users pass transparently through Clerk's sign-up.
struct ManagedSignInControls: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL

    let showsGoogleOption: Bool
    let activatesManagedProvider: Bool

    init(showsGoogleOption: Bool = true, activatesManagedProvider: Bool = true) {
        self.showsGoogleOption = showsGoogleOption
        self.activatesManagedProvider = activatesManagedProvider
    }

    private var isHuntMode: Bool { ProwlHuntRuntime.current.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.managedSignInStage == .idle {
                if showsGoogleOption {
                    Button {
                        Task {
                            await appState.startManagedGoogleSignIn { openURL($0) }
                        }
                    } label: {
                        signInLabel(busy: appState.managedBusyAction == .google, title: "Continue with Google")
                    }
                    .disabled(appState.isManagedBusy)
                    .accessibilityIdentifier("managedGoogleSignInButton")

                    Text("or use your email").font(.caption).foregroundStyle(.secondary)
                }

                TextField("Email address", text: $appState.managedEmailInput)
                    .textContentType(.username)
                    .textFieldStyle(.roundedBorder)
                    .disabled(appState.isManagedBusy)
                    .accessibilityIdentifier("managedEmailField")
                Button {
                    Task { await appState.startManagedSignIn() }
                } label: {
                    signInLabel(busy: appState.managedBusyAction == .emailCode, title: "Send sign-in code")
                }
                .disabled(appState.isManagedBusy)
                .accessibilityIdentifier("managedSendCodeButton")
            } else if appState.managedSignInStage == .codeSent {
                Text("Enter the code we emailed to \(appState.managedEmailInput).")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("6-digit code", text: $appState.managedCodeInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("managedCodeField")
                HStack {
                    Button {
                        Task { await appState.verifyManagedCode(activatesManagedProvider: activatesManagedProvider) }
                    } label: {
                        signInLabel(busy: appState.managedBusyAction == .verifyCode, title: "Verify & connect")
                    }
                    .disabled(appState.isManagedBusy)
                    .accessibilityIdentifier("managedVerifyButton")
                    Button("Use a different email") {
                        Task { await appState.cancelManagedSignInFlow() }
                    }
                        .disabled(appState.isManagedBusy)
                        .buttonStyle(.link)
                }
            } else {
                Label("Finish signing in in your browser.", systemImage: "safari")
                    .font(.callout)
                Text("A browser window opened — approve the sign-in there, then you'll be brought back automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel") {
                    Task { await appState.cancelManagedSignInFlow() }
                }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("managedCancelBrowserSignIn")
                // Hunt-only: complete the (faked) browser sign-in deterministically,
                // since a Prowl hunt cannot drive a real browser round-trip.
                if isHuntMode {
                    Button("Simulate browser sign-in (Prowl hunt)") {
                        appState.completeManagedGoogleSignInForHunt()
                    }
                    .accessibilityIdentifier("managedSimulateGoogleCallback")
                }
            }
            if isHuntMode {
                Text("Prowl hunt: sign-in uses a deterministic offline fake.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // A stale error shouldn't linger once the user starts correcting it.
        .onChange(of: appState.managedEmailInput) { _, _ in appState.managedError = nil }
        .onChange(of: appState.managedCodeInput) { _, _ in appState.managedError = nil }
    }

    @ViewBuilder
    private func signInLabel(busy: Bool, title: String) -> some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            Text(title)
        }
    }
}

/// The guided bring-your-own-provider controls (item 59): featured OpenRouter
/// one-click, a provider picker with per-provider key guidance, model/base-URL/key
/// + Test Connection, the connected state, and the privacy note. Managed is
/// excluded from the picker — it lives in its own card above.
struct BYOProviderControls: View {
    @EnvironmentObject var appState: AppState

    /// The provider highlighted in the picker. Staged locally so opening the
    /// picker doesn't immediately switch the active provider; "Use this provider"
    /// makes the switch. Synced to the active provider when BYO is live.
    @State private var stagedProvider: LLMProviderKind = .anthropic

    private var byoProviders: [LLMProviderKind] {
        LLMProviderKind.allCases.filter { $0 != .managed }
    }

    /// Whether the staged provider is the one currently drafting.
    private var isStagedProviderActive: Bool {
        appState.llmProviderKind == stagedProvider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OpenRouterProvisionCard()

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
                Button("Use this provider") { appState.selectLLMProvider(stagedProvider) }
                    .accessibilityIdentifier("useThisProviderButton")
                ProviderKeyGuidance(provider: stagedProvider)
            }

            BYOProviderErrorMessage()
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
                appState.disconnectLLM(provider: appState.llmProviderKind)
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
                Task { await appState.testLLMConnection() }
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
            set: { appState.updateLLMBaseURLFromUser($0) }
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
