import SwiftUI

/// First-run setup wizard. Walks a new user through connecting a mailbox,
/// configuring an AI provider, choosing send behavior, and kicking off voice
/// learning. Steps 1 and 2 gate advancing on a passing live test; the voice
/// step is skippable. Reuses the same `AppState` actions as Settings.
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var step: AppState.OnboardingStep

    /// Closes the onboarding window (supplied by the presenter).
    let onFinish: () -> Void

    init(initialStep: AppState.OnboardingStep = .connectAccount, onFinish: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let reason = appState.onboardingContinueBlockedReason(for: step) {
                continueBlockedHint(reason)
            }
            Divider()
            navigationBar
        }
        .frame(width: 460, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            Text("Welcome to Sentwise")
                .font(.headline)
            stepIndicator
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(AppState.OnboardingStep.allCases) { item in
                Circle()
                    .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel("Step \(step.rawValue + 1) of \(AppState.OnboardingStep.allCases.count)")
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .connectAccount: OnboardingAccountStep()
        case .connectProvider: OnboardingProviderStep()
        case .sendBehavior: OnboardingSendBehaviorStep()
        case .voice: OnboardingVoiceStep()
        }
    }

    /// Explains why Continue is disabled, so the gate on the connect steps isn't
    /// silent. Placed just above the navigation bar, next to the button it's about.
    private func continueBlockedHint(_ reason: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text(reason)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack {
            if let previous = step.previous {
                Button("Back") { withAnimation { step = previous } }
            }
            Spacer()
            if step == .voice {
                Button("Skip for now") { finish() }
                Button("Finish") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!appState.canFinishOnboarding)
            } else {
                Button("Continue") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
            }
        }
        .padding(16)
    }

    /// Whether the current step's prerequisites are met so the user can advance.
    private var canAdvance: Bool {
        switch step {
        case .connectAccount: return appState.isAccountConnected
        case .connectProvider: return appState.isLLMConnected
        case .sendBehavior, .voice: return true
        }
    }

    private func advance() {
        if let next = step.next { withAnimation { step = next } }
    }

    private func finish() {
        appState.completeOnboarding()
        onFinish()
    }
}

// MARK: - Shared building blocks

/// A step's title and one-line explanation.
private struct StepHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3).bold()
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

/// A green "connected" confirmation row.
struct ConnectedBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.green)
    }
}

/// A red inline error line.
struct OnboardingError: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
    }
}

// MARK: - Step 1: Connect account

private struct OnboardingAccountStep: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isMailEmailFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeading(
                title: "Connect your inbox",
                subtitle: "Sentwise reads your inbox and Sent mail over IMAP using an app password."
            )

            if appState.isAccountConnected {
                ConnectedBadge(text: "Connected as \(appState.mailEmail)")
                Button("Disconnect", role: .destructive) { appState.disconnectMail() }
                    .disabled(appState.isConnecting)
            } else {
                TextField("Email address", text: mailEmailBinding)
                    .textContentType(.username)
                    .textFieldStyle(.roundedBorder)
                    .focused($isMailEmailFocused)
                    .onSubmit { appState.commitMailEmailEditFromUser() }
                    .onChange(of: isMailEmailFocused) { _, isFocused in
                        if !isFocused {
                            appState.commitMailEmailEditFromUser()
                        }
                    }
                SecureField("App password", text: $appState.mailAppPassword)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await appState.testConnection() }
                } label: {
                    if appState.isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(appState.isConnecting)

                AppPasswordGuidanceView(
                    email: appState.mailEmail,
                    explicitHostFallback: appState.credentialGuidanceHostFallback
                )

                DisclosureGroup("Advanced (IMAP server)") {
                    TextField("IMAP host", text: mailHostBinding)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", value: $appState.mailPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let error = appState.connectionError {
                OnboardingError(message: error)
            }

            Text(AppState.privacyStatement)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var mailHostBinding: Binding<String> {
        Binding(
            get: { appState.mailHost },
            set: { appState.updateMailHostFromUser($0) }
        )
    }

    private var mailEmailBinding: Binding<String> {
        Binding(
            get: { appState.mailEmail },
            set: { appState.updateMailEmailFromUser($0) }
        )
    }
}

// MARK: - Step 2: Connect provider

private struct OnboardingProviderStep: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeading(
                title: "Choose your AI",
                subtitle: "Sentwise includes the AI — just sign in. Power users can bring their own."
            )

            ManagedInferenceCard()

            // Subdued escape hatch: the full BYO provider controls, tucked away so
            // Marcus never has to read it but Sam can find it (item 59).
            DisclosureGroup("Use your own AI provider instead") {
                BYOProviderControls()
                    .padding(.top, 6)
            }
            .accessibilityIdentifier("useOwnProviderDisclosure")
        }
    }
}

// MARK: - Step 3: Send behavior

private struct OnboardingSendBehaviorStep: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeading(
                title: "When you approve a draft",
                subtitle: "Choose what one-tap approval does. You can change this later in Settings."
            )

            Picker("On approve", selection: $appState.sendBehavior) {
                Text("Save as draft").tag(SendBehavior.saveAsDraft)
                Text("Send immediately").tag(SendBehavior.autoSend)
            }
            .pickerStyle(.radioGroup)

            Text(appState.sendBehavior == .autoSend
                 ? "Approving a draft sends it right away over SMTP."
                 : "Approving a draft saves it to your Gmail Drafts to send yourself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Step 4: Voice

private struct OnboardingVoiceStep: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeading(
                title: "Learn your writing voice",
                subtitle: "Sentwise studies your Sent mail so drafts sound like you, not a bot."
            )

            if let profile = appState.voiceProfile {
                ConnectedBadge(text: profile.summary.isEmpty
                    ? "Learned from \(profile.sampleCount) sent message\(profile.sampleCount == 1 ? "" : "s")."
                    : profile.summary)
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

            Text("This is optional — you can skip it and learn later from Settings. Your "
                 + "voice keeps improving as you send more mail.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = appState.voiceError {
                OnboardingError(message: error)
            }
        }
    }
}
