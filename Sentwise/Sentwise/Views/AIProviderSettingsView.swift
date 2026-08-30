import SwiftUI

/// The "AI Provider" tab of Settings: the managed-inference (Sentwise AI) account,
/// the guided bring-your-own-provider path (item 59), and voice learning (which
/// depends on both a connected account and a connected provider).
struct AIProviderSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Sentwise AI") {
                Text("Included with your subscription — no API key needed. 14-day free trial.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.isManagedSignedIn {
                    LabeledContent("Account") {
                        Text(appState.managedAccountEmail).foregroundStyle(.secondary)
                    }
                    if appState.isManagedProviderActive {
                        LabeledContent("Status") { ActiveProviderBadge() }
                    } else {
                        Button("Use Sentwise AI") { appState.selectLLMProvider(.managed) }
                            .accessibilityIdentifier("useManagedInference")
                            .accessibilityLabel("Use Sentwise AI")
                    }
                    // Weekly usage allotment + own-key valve (item 56b).
                    ManagedUsageView()
                    Button("Sign out", role: .destructive) {
                        Task { await appState.signOutManaged() }
                    }
                    .disabled(appState.isManagedBusy)
                    .accessibilityIdentifier("managedSignOutButton")
                    .accessibilityLabel("Sign out of Sentwise AI")
                } else {
                    if !appState.isManagedProviderActive {
                        Button("Use Sentwise AI") { appState.selectLLMProvider(.managed) }
                            .accessibilityIdentifier("useManagedInference")
                            .accessibilityLabel("Use Sentwise AI")
                    }
                    Text("Sign in or create your account")
                        .font(.caption).foregroundStyle(.secondary)
                    ManagedSignInControls()
                }
                ManagedAccountErrorMessage()
            }

            Section("Use your own AI") {
                BYOProviderControls()
            }

            Section("Voice") {
                if let profile = appState.voiceProfile {
                    Text(profile.summary.isEmpty
                         ? "Learned from \(profile.sampleCount) sent message\(profile.sampleCount == 1 ? "" : "s")."
                         : profile.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Learn your writing voice from your Sent mail so drafts sound like you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await appState.learnVoiceProfile() }
                } label: {
                    if appState.isLearningVoice {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            if let progress = appState.voiceProgress {
                                Text(progress).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(appState.voiceProfile == nil ? "Learn my voice" : "Re-learn")
                    }
                }
                .disabled(appState.isLearningVoice || !appState.canLearnVoice)
                .accessibilityLabel(appState.voiceProfile == nil ? "Learn my voice" : "Re-learn my voice")

                if appState.voiceProfile != nil {
                    Button("Forget voice profile", role: .destructive) {
                        appState.forgetVoiceProfile()
                    }
                    .disabled(appState.isLearningVoice)
                    .accessibilityLabel("Forget voice profile")
                }

                if !appState.canLearnVoice && appState.voiceProfile == nil {
                    Text("Connect an email account and an AI provider first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = appState.voiceError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}
