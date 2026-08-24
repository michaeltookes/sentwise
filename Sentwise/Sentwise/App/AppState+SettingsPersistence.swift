import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "SettingsPersistence")

/// Builds and persists the `Settings` snapshot from `AppState`'s live published
/// values. Kept in its own file so `AppState` stays within lint limits.
extension AppState {

    /// Builds a `Settings` snapshot from the current published values.
    /// Internal so the `AppState+Onboarding` extension can persist the
    /// onboarding flag through the same path.
    func buildSettings(
        mailEmail: String? = nil,
        mailHost: String? = nil,
        mailPort: Int? = nil,
        llmModelOverride: String? = nil
    ) -> Settings {
        Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: pollIntervalSeconds,
            mailEmail: (mailEmail ?? self.mailEmail).trimmingCharacters(in: .whitespacesAndNewlines),
            mailHost: (mailHost ?? self.mailHost).trimmingCharacters(in: .whitespacesAndNewlines),
            mailHostGuidanceEmail: mailHostExplicitlyEditedEmail,
            mailHostGuidancePendingEmail: mailHostExplicitlyEditedBeforeEmail,
            mailPort: mailPort ?? self.mailPort,
            savedAccounts: savedAccounts,
            llmProvider: llmProviderKind.rawValue,
            llmModel: (llmModelOverride ?? self.llmModel).trimmingCharacters(in: .whitespacesAndNewlines),
            llmBaseURL: llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            llmVerifiedModel: verifiedLLMModel,
            managedAccountEmail: managedAccountEmail,
            signaturePolicy: signaturePolicy.rawValue,
            signatureText: signatureText,
            sendBehavior: sendBehavior.rawValue,
            sendDelaySeconds: sendDelaySeconds,
            onboardingCompleted: onboardingCompleted,
            senderAllowlist: senderAllowlist,
            senderBlocklist: senderBlocklist,
            transcriptWatchedFolderEnabled: transcriptWatchedFolderEnabled,
            transcriptWatchedFolderPath: transcriptWatchedFolderPath,
            transcriptWatchedFolderSeenSnapshots: transcriptWatchedFolderSeenSnapshots
        )
    }

    /// Saves settings to disk (debounced).
    func saveSettings(llmModel: String? = nil) {
        let settings = buildSettings(llmModelOverride: llmModel)
        settingsDebouncer.debounce { [weak self] in
            self?.persistence.saveSettings(settings)
        }
    }

    /// Saves a specific settings snapshot immediately, cancelling stale
    /// debounced snapshots first.
    func persistSettingsSync(_ settings: Settings) throws {
        settingsDebouncer.cancel()
        try persistence.saveSettingsSync(settings)
    }

    /// Saves settings immediately (used on app termination).
    func saveSettingsSync() {
        let settings = buildSettings()
        do {
            try persistSettingsSync(settings)
        } catch {
            connectionError = Self.settingsMessage(action: "save", error: error)
            logger.error("Failed to save settings synchronously: \(error.localizedDescription)")
        }
    }
}
