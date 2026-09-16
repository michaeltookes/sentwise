import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "SavedAccounts")

struct ActiveMailPasswordRemoval {
    let accountEmail: String
    let accountPassword: String?
    let legacyPassword: String?
}

/// Saved-accounts management (item 48): remembering multiple accounts, switching
/// between them without re-entry, and per-account Keychain secrets.
extension AppState {

    // MARK: - Per-account secret access

    /// Reads the stored app password for `email`, preferring the per-account
    /// Keychain key and falling back to the legacy shared slot for pre-migration
    /// installs (or test fixtures on the legacy key). Never surfaced anywhere.
    static func storedMailPassword(
        forEmail email: String,
        savedAccounts: [SavedMailAccount],
        activeEmail: String? = nil,
        secrets: SecretStore
    ) -> String? {
        let normalized = SavedMailAccount.normalizedEmail(email)
        // No email means no password to read — never surface a stray legacy secret.
        guard !normalized.isEmpty else { return nil }

        if let perAccount = (try? secrets.value(for: .mailAppPassword(email: normalized))) ?? nil,
           !perAccount.isEmpty {
            return perAccount
        }
        // Legacy fallback: a pre-v11 install whose secret has not yet moved (or a
        // test fixture on the old shared slot). The shared slot can only belong to
        // the migrated original account, so never hand it to another account.
        guard (try? legacyMailPasswordOwnerID(
            savedAccounts: savedAccounts,
            activeEmail: activeEmail,
            secrets: secrets
        )) == normalized,
              let legacy = (try? secrets.value(for: .mailAppPassword)) ?? nil,
              !legacy.isEmpty else {
            return nil
        }
        return legacy
    }

    static func storedMailPassword(forEmail email: String, settings: Settings, secrets: SecretStore) -> String? {
        storedMailPassword(
            forEmail: email,
            savedAccounts: settings.savedAccounts,
            activeEmail: settings.mailEmail,
            secrets: secrets
        )
    }

    private static func legacyMailPasswordOwnerID(
        savedAccounts: [SavedMailAccount],
        activeEmail: String?,
        secrets: SecretStore
    ) throws -> String? {
        guard let legacy = try secrets.value(for: .mailAppPassword), !legacy.isEmpty else {
            return nil
        }
        if let migratedAccount = savedAccounts.first {
            return migratedAccount.id
        }

        let normalizedActiveEmail = SavedMailAccount.normalizedEmail(activeEmail ?? "")
        guard !normalizedActiveEmail.isEmpty else { return nil }
        let activePassword = try secrets.value(for: .mailAppPassword(email: normalizedActiveEmail))
        if activePassword?.isEmpty != false {
            return normalizedActiveEmail
        }
        return nil
    }

    private func legacyMailPasswordOwnerID() throws -> String? {
        try Self.legacyMailPasswordOwnerID(
            savedAccounts: savedAccounts,
            activeEmail: mailEmail,
            secrets: secrets
        )
    }

    func legacyMailPasswordForOwnedAccount(_ email: String) throws -> String? {
        guard try legacyMailPasswordOwnerID() == SavedMailAccount.normalizedEmail(email),
              let legacy = try secrets.value(for: .mailAppPassword),
              !legacy.isEmpty else {
            return nil
        }
        return legacy
    }

    /// Instance convenience over `storedMailPassword(forEmail:savedAccounts:secrets:)`.
    func storedMailPassword(forEmail email: String) -> String? {
        Self.storedMailPassword(
            forEmail: email,
            savedAccounts: savedAccounts,
            activeEmail: mailEmail,
            secrets: secrets
        )
    }

    /// Removes the active account's password for disconnect. The legacy shared slot
    /// is removed only when it belongs to the active account (it may still back an
    /// older inactive account after a failed migration).
    func removeActiveMailPasswordForDisconnect(messageSurface: TransientMessageSurface = .shared) -> ActiveMailPasswordRemoval? {
        let activeEmail = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeKey = activeEmail.isEmpty ? nil : SecretKey.mailAppPassword(email: activeEmail)
        let activeAccountPassword: String?, activeLegacyPassword: String?

        do {
            if let activeKey {
                activeAccountPassword = try secrets.value(for: activeKey)
            } else {
                activeAccountPassword = nil
            }
            if !activeEmail.isEmpty {
                activeLegacyPassword = try legacyMailPasswordForOwnedAccount(activeEmail)
            } else {
                activeLegacyPassword = nil
            }
        } catch {
            setConnectionError(Self.keychainMessage(action: "read", error: error), for: messageSurface)
            return nil
        }

        do {
            if let activeKey, activeAccountPassword != nil {
                try secrets.remove(activeKey)
            }
            if activeLegacyPassword != nil {
                try secrets.remove(.mailAppPassword)
            }
            return ActiveMailPasswordRemoval(
                accountEmail: activeEmail,
                accountPassword: activeAccountPassword,
                legacyPassword: activeLegacyPassword
            )
        } catch {
            setConnectionError(Self.keychainMessage(action: "remove", error: error), for: messageSurface)
            return nil
        }
    }

    // MARK: - v10 → v11 migration

    /// Migrates a pre-v11 settings file to the saved-accounts model: the existing
    /// single account becomes the first saved account, and its app password moves
    /// from the legacy shared Keychain slot to a per-account key (the legacy slot is
    /// then removed so no orphaned secret remains). Idempotent; no-ops once at v11.
    static func migratedSavedAccountsSettings(
        _ settings: Settings,
        secrets: SecretStore,
        persistence: PersistenceProvider
    ) -> Settings {
        migratedSavedAccountsSettings(
            settings,
            secrets: secrets,
            persistence: persistence,
            targetSchemaVersion: Settings.currentSchemaVersion,
            shouldPersist: true
        )
    }

    static func migratedSavedAccountsSettings(
        _ settings: Settings,
        secrets: SecretStore,
        persistence: PersistenceProvider,
        targetSchemaVersion: Int,
        shouldPersist: Bool
    ) -> Settings {
        guard settings.schemaVersion < Settings.savedAccountsSchemaVersion else { return settings }

        var migrated = settings
        let email = settings.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        if !email.isEmpty {
            migrateLegacyMailSecret(forEmail: email, secrets: secrets)
            if !migrated.savedAccounts.contains(where: { $0.id == SavedMailAccount.normalizedEmail(email) }) {
                migrated.savedAccounts.insert(
                    SavedMailAccount(email: email, host: settings.mailHost, port: settings.mailPort),
                    at: 0
                )
            }
        }

        migrated.schemaVersion = targetSchemaVersion
        if shouldPersist {
            do {
                try persistence.saveSettingsSync(migrated)
            } catch {
                logger.error("Failed to persist saved-accounts migration: \(error.localizedDescription)")
            }
        }
        return migrated
    }

    /// Moves the legacy shared app-password secret to the per-account key for
    /// `email`, then removes the legacy item. No-op when there is nothing to move.
    private static func migrateLegacyMailSecret(forEmail email: String, secrets: SecretStore) {
        guard let legacyPassword = (try? secrets.value(for: .mailAppPassword)) ?? nil,
              !legacyPassword.isEmpty else {
            return
        }
        let perAccountKey = SecretKey.mailAppPassword(email: email)
        let existing = (try? secrets.value(for: perAccountKey)) ?? nil
        do {
            if existing == nil || existing?.isEmpty == true {
                try secrets.set(legacyPassword, for: perAccountKey)
            }
            try secrets.remove(.mailAppPassword)
            logger.info("Migrated mail app password to a per-account Keychain key")
        } catch {
            logger.error("Failed to migrate legacy mail secret: \(error.localizedDescription)")
        }
    }

    // MARK: - Saved-account list mutation

    /// Inserts or updates the saved-account entry for these connection details.
    func upsertSavedAccount(email: String, host: String, port: Int) {
        let account = SavedMailAccount(email: email, host: host, port: port)
        guard !account.id.isEmpty else { return }
        if let index = savedAccounts.firstIndex(where: { $0.id == account.id }) {
            if savedAccounts[index] != account { savedAccounts[index] = account }
        } else {
            savedAccounts.append(account)
        }
    }

    /// Whether `account` is the one currently connected.
    func isActiveAccount(_ account: SavedMailAccount) -> Bool {
        isAccountConnected
            && SavedMailAccount.normalizedEmail(mailEmail) == account.id
    }

    // MARK: - Switching

    /// Switches to a previously saved account using its stored credentials, with no
    /// re-entry (item 48). Tears down the active account cleanly (stops watching,
    /// cancels send countdowns, clears account-scoped preview/browser/cleanup state)
    /// and connects the target through the normal verify path. Both accounts' secrets
    /// are retained — only the *active* pointer moves; pending drafts stay scoped to
    /// their originating account by identity.
    func switchToSavedAccount(_ account: SavedMailAccount, messageSurface: TransientMessageSurface = .shared) async {
        clearWorkspaceAuthGuidance(for: messageSurface)
        guard !isActiveAccount(account) else { return }

        guard let password = storedMailPassword(forEmail: account.email), !password.isEmpty else {
            setConnectionError("No saved password for \(account.email). Reconnect this account to continue.", for: messageSurface)
            return
        }

        let outgoingSettings = buildSettings()
        // Clean teardown of the outgoing account before adopting the new one.
        let wasWatching = watchStatus == .watching
        stopWatching()
        cancelAllSendCountdowns()

        let credentials = MailAccountCredentials(
            email: account.email,
            appPassword: password,
            host: account.host,
            port: account.port
        )
        let localDataGeneration = localDataEraseGeneration
        let didConnect = await testConnection(with: credentials, messageSurface: messageSurface) { _ in
            self.isCurrentLocalDataGeneration(localDataGeneration)
        }

        guard isCurrentLocalDataGeneration(localDataGeneration) else { return }

        guard didConnect, isAccountConnected, isActiveAccount(account) else {
            restoreConnectionSnapshot(settings: outgoingSettings)
            if wasWatching {
                startWatchingIfReady()
            }
            return
        }

        if wasWatching {
            startWatchingIfReady()
        }
    }

    // MARK: - Verified-connection persistence

    /// Adopts verified credentials as the active account, remembers it, and persists
    /// the settings snapshot. Called from `testConnection`.
    func persistVerifiedConnection(_ credentials: MailAccountCredentials, clearSignature: Bool) throws {
        mailEmail = credentials.email
        mailHost = credentials.host
        mailPort = credentials.port
        mailAppPassword = credentials.appPassword
        markMailHostVerifiedForGuidance()
        // Remember this account so it can be switched back to without re-entry.
        upsertSavedAccount(email: credentials.email, host: credentials.host, port: credentials.port)

        let nextSettings = buildSettings(
            mailEmail: credentials.email,
            mailHost: credentials.host,
            mailPort: credentials.port,
            signaturePolicyOverride: clearSignature ? SignaturePolicy.default.rawValue : nil,
            signatureTextOverride: clearSignature ? "" : nil
        )
        try persistSettingsSync(nextSettings)
    }

    /// Restores the connecting account's Keychain slot after a failed persist.
    func rollbackMailAppPassword(to previousAppPassword: String?, for key: SecretKey) -> Error? {
        do {
            if let previousAppPassword {
                try secrets.set(previousAppPassword, for: key)
            } else {
                try secrets.remove(key)
            }
            return nil
        } catch {
            logger.error("Failed to roll back mail app password: \(error.localizedDescription)")
            return error
        }
    }

    /// Restores UI/account state to a previous settings snapshot after a failed
    /// connect. Per-account keys are isolated, so the previously-active secret is
    /// re-read honestly.
    func restoreConnectionSnapshot(settings: Settings) {
        mailEmail = settings.mailEmail
        mailHost = settings.mailHost
        mailPort = settings.mailPort
        savedAccounts = settings.savedAccounts
        mailHostExplicitlyEditedEmail = settings.mailHostGuidanceEmail
        mailHostExplicitlyEditedBeforeEmail = settings.mailHostGuidancePendingEmail
        let previousEmail = settings.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousPassword = storedMailPassword(forEmail: previousEmail) ?? ""
        mailAppPassword = previousPassword
        isAccountConnected = !previousEmail.isEmpty && !previousPassword.isEmpty
        restoreMailHostGuidanceFromSettings(settings)
    }
}
