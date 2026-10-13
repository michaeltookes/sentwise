import Foundation
import os

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "Onboarding")

/// First-run onboarding state and transitions on `AppState`. Kept in a separate
/// file so `AppState` stays within the file/type length limits.
extension AppState {

    /// The ordered steps of the first-run setup flow.
    enum OnboardingStep: Int, CaseIterable, Identifiable {
        /// Connect a mailbox (IMAP + app password).
        case connectAccount
        /// Configure and verify the LLM provider + key.
        case connectProvider
        /// Choose what approving a draft does.
        case sendBehavior
        /// Kick off (or skip) initial voice learning.
        case voice

        var id: Int { rawValue }

        /// The next step, or `nil` if this is the last one.
        var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }

        /// The previous step, or `nil` if this is the first one.
        var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    }

    /// The privacy statement shown during onboarding and in Settings. A single
    /// source of truth so the two never drift.
    static let privacyStatement =
        "Sentwise is local-first. Your mail and settings stay on this Mac, "
        + "and secrets like API keys and app passwords are stored in the macOS "
        + "Keychain — never in plaintext. Nothing leaves your machine except the "
        + "LLM request you configure and control."

    /// The step the flow should resume at: the first required step that isn't
    /// yet satisfied. Once the account and provider are connected, resume at the
    /// send-behavior step (the remaining steps have defaults / are optional).
    var onboardingResumeStep: OnboardingStep {
        if !isAccountConnected { return .connectAccount }
        if !isLLMConnected { return .connectProvider }
        return .sendBehavior
    }

    /// Whether the required prerequisites (account + provider) are connected, so
    /// the flow can be finished.
    var canFinishOnboarding: Bool {
        isAccountConnected && isLLMConnected
    }

    /// Helper text explaining why Continue is disabled on a connect step, or
    /// `nil` once the step's prerequisite is satisfied (so nothing needs saying).
    ///
    /// Both connect steps gate advancing on a passing live test, but nothing on
    /// the screen said so — the button was just silently disabled. Surfacing the
    /// reason is what unblocks a non-technical first-run user.
    func onboardingContinueBlockedReason(for step: OnboardingStep) -> String? {
        switch step {
        case .connectAccount:
            return isAccountConnected ? nil : "Run Test Connection to continue."
        case .connectProvider:
            guard !isLLMConnected else { return nil }
            return llmProviderKind == .managed
                ? "Sign in to Sentwise AI to continue."
                : "Run Test Connection to continue."
        case .sendBehavior, .voice:
            return nil
        }
    }

    /// Marks onboarding complete, persists the flag, and starts watching from an
    /// idle state if the account + provider are ready. Idempotent.
    func completeOnboarding() {
        guard !onboardingCompleted else { return }

        let shouldAutoStartWatching = watchStatus == .idle
        onboardingCompleted = true
        persistOnboardingCompletion()
        if shouldAutoStartWatching {
            startWatchingIfReady()
        }
    }

    /// At launch, treat an already-configured install as onboarded so existing
    /// users are never sent back through the flow. Returns `true` if onboarding
    /// still needs to be shown.
    @discardableResult
    func reconcileOnboardingState() -> Bool {
        if !onboardingCompleted,
           loadedSettingsPredateOnboardingCompletion,
           canFinishOnboarding {
            onboardingCompleted = true
            persistOnboardingCompletion()
        }
        return !onboardingCompleted
    }

    /// Persists just the onboarding flag durably, without disturbing the
    /// connection-error surface used by the mail/LLM flows. Reuses
    /// `buildSettings()` so the snapshot stays consistent with every other save.
    private func persistOnboardingCompletion() {
        do {
            try persistSettingsSync(buildSettings())
        } catch {
            logger.error("Failed to persist onboarding completion: \(error.localizedDescription)")
        }
    }
}
