import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "SettingsMigration")

/// Launch-time settings migrations on `AppState`. Split out of
/// `AppState+ManagedAccount` (item 100) so both files stay within length limits.
/// The chain advances an older settings file to the current schema, persisting
/// exactly once at the terminal step.
extension AppState {

    // MARK: - Migration (items 56a, 100)

    /// Runs all launch-time settings migrations in order: the saved-accounts move
    /// (item 48), the managed-inference default (item 56a), the additive signature
    /// schema (item 24), then the BYOK-parked fallback (item 100). Only the terminal
    /// step persists, so a launch that migrates writes the fully-migrated settings
    /// exactly once, at the current schema version. Keeps `AppState.init` short.
    static func fullyMigratedSettings(
        loaded: Settings,
        secrets: SecretStore,
        persistence: PersistenceProvider
    ) -> Settings {
        let accountsMigrated = migratedSavedAccountsSettings(
            loaded,
            secrets: secrets,
            persistence: persistence,
            targetSchemaVersion: Settings.managedInferenceSchemaVersion - 1,
            shouldPersist: false
        )
        let managedMigrated = migratedManagedInferenceSettings(
            accountsMigrated,
            originalSchemaVersion: loaded.schemaVersion,
            secrets: secrets,
            persistence: persistence,
            targetSchemaVersion: Settings.signatureSchemaVersion - 1,
            shouldPersist: false
        )
        let signatureMigrated = migratedSignatureSettings(
            managedMigrated,
            originalSchemaVersion: loaded.schemaVersion,
            persistence: persistence,
            targetSchemaVersion: Settings.byokParkedSchemaVersion - 1,
            shouldPersist: false
        )
        return migratedBYOKParkedSettings(
            signatureMigrated,
            originalSchemaVersion: loaded.schemaVersion,
            secrets: secrets,
            persistence: persistence
        )
    }

    /// Moves an existing install with no configured BYO provider onto managed
    /// inference. A configured BYO user (a stored key or a verified model) keeps
    /// their provider. Runs once, gated on the original schema version.
    ///
    /// `targetSchemaVersion` defaults to the managed-inference version this step
    /// introduces (15); the full launch chain passes the version just below the
    /// next step so only the terminal migration advances to the current version.
    /// `shouldPersist` lets the chain defer the single write to that terminal step.
    static func migratedManagedInferenceSettings(
        _ settings: Settings,
        originalSchemaVersion: Int,
        secrets: SecretStore,
        persistence: PersistenceProvider,
        targetSchemaVersion: Int = Settings.managedInferenceSchemaVersion,
        shouldPersist: Bool = true
    ) -> Settings {
        guard originalSchemaVersion < Settings.managedInferenceSchemaVersion else { return settings }
        var migrated = settings

        let provider = LLMProviderKind(rawValue: settings.llmProvider) ?? .managed
        if provider != .managed {
            let apiKeySecret = Self.llmAPIKeySecret(
                provider: provider,
                baseURL: provider.supportsCustomBaseURL ? settings.llmBaseURL : nil
            )
            let hasKey = secrets.hasValue(for: apiKeySecret)
                || (apiKeySecret != provider.apiKeySecret && secrets.hasValue(for: provider.apiKeySecret))
            let hasVerifiedModel = !settings.llmVerifiedModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isConfigured = hasKey || hasVerifiedModel
            if !isConfigured {
                migrated.llmProvider = "managed"
                migrated.llmModel = ""
            }
        }

        migrated.schemaVersion = targetSchemaVersion
        if shouldPersist, migrated != settings {
            do {
                try persistence.saveSettingsSync(migrated)
            } catch {
                logger.error("Failed to persist managed-inference migration: \(error.localizedDescription)")
            }
        }
        return migrated
    }

    /// Additive schema-advance step for the signature and later purely-additive
    /// versions. `targetSchemaVersion`/`shouldPersist` let the launch chain defer the
    /// single write to the terminal step (`migratedBYOKParkedSettings`).
    static func migratedSignatureSettings(
        _ settings: Settings,
        originalSchemaVersion: Int,
        persistence: PersistenceProvider,
        targetSchemaVersion: Int = Settings.currentSchemaVersion,
        shouldPersist: Bool = true
    ) -> Settings {
        guard originalSchemaVersion < targetSchemaVersion else { return settings }
        var migrated = settings
        migrated.schemaVersion = targetSchemaVersion
        if shouldPersist, migrated != settings {
            do {
                try persistence.saveSettingsSync(migrated)
            } catch {
                logger.error("Failed to persist signature migration: \(error.localizedDescription)")
            }
        }
        return migrated
    }

    /// Terminal launch migration. Parked 2026-09-16 (item 100): BYOK/local providers
    /// were removed from the UI and the product story; managed inference is the only
    /// shipped path. Any install that predates this version and persisted a
    /// non-managed provider silently falls back to managed here — no released builds
    /// existed, so there is no migration UI, and the parked provider code stays in the
    /// source for possible future revival. Advances the schema to the current version.
    static func migratedBYOKParkedSettings(
        _ settings: Settings,
        originalSchemaVersion: Int,
        secrets: SecretStore,
        persistence: PersistenceProvider
    ) -> Settings {
        guard originalSchemaVersion < Settings.byokParkedSchemaVersion else { return settings }
        var migrated = settings
        let clearedPendingOpenRouterState = clearPendingOpenRouterProvisioningState(secrets: secrets)
        let provider = LLMProviderKind(rawValue: settings.llmProvider) ?? .managed
        if provider != .managed {
            migrated.llmProvider = "managed"
            migrated.llmModel = ""
            migrated.llmBaseURL = ""
            migrated.llmVerifiedModel = ""
        }
        if clearedPendingOpenRouterState {
            migrated.schemaVersion = Settings.byokParkedSchemaVersion
        }
        if migrated != settings {
            do {
                try persistence.saveSettingsSync(migrated)
            } catch {
                logger.error("Failed to persist BYOK-parked migration: \(error.localizedDescription)")
            }
        }
        return migrated
    }

    private static func clearPendingOpenRouterProvisioningState(secrets: SecretStore) -> Bool {
        var didClear = true
        for key in [
            SecretKey.openRouterPKCEVerifier,
            .openRouterPKCEMessageSurface,
            .openRouterPKCEFlowID,
            .openRouterCanceledCallbackSurface
        ] {
            do {
                try secrets.remove(key)
            } catch {
                didClear = false
                logger.error("Failed to clear pending OpenRouter provisioning state: \(error.localizedDescription)")
            }
        }
        return didClear
    }
}
