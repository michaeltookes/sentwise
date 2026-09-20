import SwiftUI

/// Shared managed-inference (Sentwise AI) controls used by both onboarding and
/// Settings (item 56a): the managed sign-in card, its error surface, and the
/// email-code/Google sign-in controls. Extracted from `OnboardingView` to keep that
/// file within length limits. (The bring-your-own-provider controls were parked
/// 2026-09-16 — item 100 — and live in `BYOProviderGuidance.swift`.)

/// A green "Active" pill marking the drafting provider. With managed-only (item
/// 100) there is a single provider, but the badge still reads clearly in the
/// managed card and Settings status row.
struct ActiveProviderBadge: View {
    var body: some View {
        Label("Active", systemImage: "checkmark.seal.fill")
            .font(.caption).bold()
            .foregroundStyle(.green)
            .accessibilityIdentifier("activeProviderBadge")
            .accessibilityLabel("Active provider")
    }
}

/// The primary, pre-selected managed-inference option: sign in and draft, no key.
struct ManagedInferenceCard: View {
    @EnvironmentObject var appState: AppState
    let messageSurface: AppState.TransientMessageSurface

    init(messageSurface: AppState.TransientMessageSurface = .shared) {
        self.messageSurface = messageSurface
    }

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
                Button("Use Sentwise AI") { appState.selectLLMProvider(.managed, messageSurface: messageSurface) }
                    .accessibilityIdentifier("useManagedInference")
            } else if appState.isManagedSignedIn {
                ConnectedBadge(text: "Connected as \(appState.managedAccountEmail)")
                Button("Sign out") { Task { await appState.signOutManaged(messageSurface: messageSurface) } }
                    .disabled(appState.isManagedBusy)
                    .accessibilityIdentifier("managedSignOutButton")
            } else {
                Text("Sign in or create your account")
                    .font(.caption).foregroundStyle(.secondary)
                ManagedSignInControls(messageSurface: messageSurface)
            }
            ManagedAccountErrorMessage(messageSurface: messageSurface)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

/// Managed-account errors live at the enclosing provider level so sign-in and
/// sign-out failures remain visible in both signed-in and signed-out states.
struct ManagedAccountErrorMessage: View {
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
        if let error = appState.managedError(for: messageSurface) {
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
        appState.markSettingsManagedCallbackErrorDisplayed(
            for: messageSurface,
            visibleIn: settingsDisplayTab
        )
    }
}

/// Sign-in controls for the managed account: one-click Google alongside the
/// email-code flow. First-time users pass transparently through Clerk's sign-up.
struct ManagedSignInControls: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL

    let showsGoogleOption: Bool
    let activatesManagedProvider: Bool
    let messageSurface: AppState.TransientMessageSurface

    init(
        showsGoogleOption: Bool = true,
        activatesManagedProvider: Bool = true,
        messageSurface: AppState.TransientMessageSurface = .shared
    ) {
        self.showsGoogleOption = showsGoogleOption
        self.activatesManagedProvider = activatesManagedProvider
        self.messageSurface = messageSurface
    }

    private var isHuntMode: Bool { ProwlHuntRuntime.current.isEnabled }
    private var shouldShowGoogleOption: Bool {
        showsGoogleOption && (AppState.isManagedGoogleSignInEnabled || isHuntMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.managedSignInStage == .idle {
                if shouldShowGoogleOption {
                    Button {
                        Task {
                            await appState.startManagedGoogleSignIn(
                                openURL: { openURL($0) },
                                activatesManagedProvider: activatesManagedProvider,
                                messageSurface: messageSurface
                            )
                        }
                    } label: {
                        signInLabel(busy: appState.managedBusyAction == .google, title: "Continue with Google")
                    }
                    .disabled(appState.isManagedBusy)
                    .accessibilityIdentifier("managedGoogleSignInButton")

                    Text("or use your email").font(.caption).foregroundStyle(.secondary)
                }

                TextField("Email address", text: emailInputBinding)
                    .textContentType(.username)
                    .textFieldStyle(.roundedBorder)
                    .disabled(appState.isManagedBusy)
                    .accessibilityIdentifier("managedEmailField")
                Button {
                    Task {
                        await appState.startManagedSignIn(
                            activatesManagedProvider: activatesManagedProvider,
                            messageSurface: messageSurface
                        )
                    }
                } label: {
                    signInLabel(busy: appState.managedBusyAction == .emailCode, title: "Send sign-in code")
                }
                .disabled(appState.isManagedBusy)
                .accessibilityIdentifier("managedSendCodeButton")
            } else if appState.managedSignInStage == .codeSent {
                Text("Enter the code we emailed to \(appState.managedEmailInput).")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("6-digit code", text: codeInputBinding)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("managedCodeField")
                HStack {
                    Button {
                        Task { await appState.verifyManagedCode(messageSurface: messageSurface) }
                    } label: {
                        signInLabel(busy: appState.managedBusyAction == .verifyCode, title: "Verify & connect")
                    }
                    .disabled(appState.isManagedBusy)
                    .accessibilityIdentifier("managedVerifyButton")
                    Button("Use a different email") {
                        Task { await appState.cancelManagedSignInFlow(messageSurface: messageSurface) }
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
                    Task { await appState.cancelManagedSignInFlow(messageSurface: messageSurface) }
                }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("managedCancelBrowserSignIn")
                // Hunt-only: complete the (faked) browser sign-in deterministically,
                // since a Prowl hunt cannot drive a real browser round-trip.
                if isHuntMode {
                    Button("Simulate browser sign-in (Prowl hunt)") {
                        appState.completeManagedGoogleSignInForHunt(messageSurface: messageSurface)
                    }
                    .accessibilityIdentifier("managedSimulateGoogleCallback")
                }
            }
            if isHuntMode {
                Text("Prowl hunt: sign-in uses a deterministic offline fake.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func signInLabel(busy: Bool, title: String) -> some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            Text(title)
        }
    }

    private var emailInputBinding: Binding<String> {
        Binding(
            get: { appState.managedEmailInput },
            set: { appState.updateManagedEmailInputFromUser($0, messageSurface: messageSurface) }
        )
    }

    private var codeInputBinding: Binding<String> {
        Binding(
            get: { appState.managedCodeInput },
            set: { appState.updateManagedCodeInputFromUser($0, messageSurface: messageSurface) }
        )
    }
}
