import SwiftUI

/// Guided bring-your-own-provider building blocks (item 59): the "Active" badge,
/// the per-provider key-setup guidance, the OpenRouter one-click card, and the
/// privacy note. Shared by onboarding and Settings so the two never drift.

/// A green "Active" pill marking whichever provider is currently drafting. Only
/// one provider card ever shows this at a time.
struct ActiveProviderBadge: View {
    var body: some View {
        Label("Active", systemImage: "checkmark.seal.fill")
            .font(.caption).bold()
            .foregroundStyle(.green)
            .accessibilityIdentifier("activeProviderBadge")
            .accessibilityLabel("Active provider")
    }
}

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
                        appState.cancelOpenRouterProvisioning()
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("openRouterCancelButton")
                } else if appState.hasStoredOpenRouterCredential {
                    Button("Use saved OpenRouter key") {
                        appState.activateStoredOpenRouterProvider()
                    }
                    .disabled(appState.isTestingLLM)
                    .accessibilityIdentifier("openRouterUseSavedButton")
                } else {
                    Button {
                        // Hunt mode: complete deterministically offline — no browser,
                        // no PKCE exchange, no real key. Production opens the browser.
                        if isHuntMode {
                            appState.completeOpenRouterProvisioningForHunt()
                        } else if let url = appState.beginOpenRouterProvisioning() {
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
