import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "SavedAccounts")

private struct SavedAccountRemovalContext {
    let shouldClearCurrentAccount: Bool
    let ownsWorkspaceGuidance: Bool
    let accountKey: SecretKey
    let previousAccountPassword: String?
    let previousLegacyPassword: String?
    let nextSettings: Settings
}

extension AppState {

    /// Removes a saved account (item 48): deletes exactly that account's Keychain
    /// secret and drops it from the list. If it was the active account, the app
    /// goes offline and the account inputs are cleared. Other accounts' secrets are
    /// never touched. When `purgeLocalData` is set the account-scoped mail artifacts
    /// are purged before the irreversible removal so a failed erase stays retryable.
    func removeSavedAccount(
        _ account: SavedMailAccount,
        purgeLocalData: Bool = false,
        messageSurface: TransientMessageSurface = .shared
    ) {
        setConnectionError(nil, for: messageSurface)
        guard !isConnecting else {
            setConnectionError("Wait for the current connection test to finish before removing an account.", for: messageSurface)
            return
        }

        let context: SavedAccountRemovalContext
        do {
            context = try savedAccountRemovalContext(for: account, messageSurface: messageSurface)
        } catch {
            setConnectionError(Self.keychainMessage(action: "read", error: error), for: messageSurface)
            return
        }

        let shouldRestoreWatching = purgeLocalData && context.shouldClearCurrentAccount && watchStatus == .watching
        guard purgeRemovedSavedAccountDataIfNeeded(
            account,
            context: context,
            purgeLocalData: purgeLocalData,
            messageSurface: messageSurface
        ) else { return }
        guard removeSavedAccountSecrets(account, context: context, messageSurface: messageSurface) else {
            restoreWatchingAfterPreservedSavedAccountRemovalIfNeeded(shouldRestoreWatching)
            return
        }
        guard persistRemovedSavedAccountSettings(account, context: context, messageSurface: messageSurface) else {
            restoreWatchingAfterPreservedSavedAccountRemovalIfNeeded(shouldRestoreWatching)
            return
        }

        applyRemovedSavedAccountState(context, messageSurface: messageSurface)
        logger.info("Saved account removed")
    }

    func restoreActiveMailPasswordRemoval(_ removal: ActiveMailPasswordRemoval) -> Error? {
        restoreRemovedAccountSecrets(
            accountEmail: removal.accountEmail,
            accountPassword: removal.accountPassword,
            legacyPassword: removal.legacyPassword
        )
    }

    private func savedAccountRemovalContext(
        for account: SavedMailAccount,
        messageSurface: TransientMessageSurface
    ) throws -> SavedAccountRemovalContext {
        let wasCurrentAccount = SavedMailAccount.normalizedEmail(mailEmail) == account.id
        let shouldClearCurrentAccount = isActiveAccount(account) || wasCurrentAccount
        let accountKey = SecretKey.mailAppPassword(email: account.email)
        return SavedAccountRemovalContext(
            shouldClearCurrentAccount: shouldClearCurrentAccount,
            ownsWorkspaceGuidance: workspaceAuthGuidanceAccountID(for: messageSurface) == account.id,
            accountKey: accountKey,
            previousAccountPassword: try secrets.value(for: accountKey),
            previousLegacyPassword: try legacyMailPasswordForOwnedAccount(account.email),
            nextSettings: settingsAfterRemovingSavedAccount(account, clearCurrentAccount: shouldClearCurrentAccount)
        )
    }

    private func removeSavedAccountSecrets(
        _ account: SavedMailAccount,
        context: SavedAccountRemovalContext,
        messageSurface: TransientMessageSurface
    ) -> Bool {
        do {
            try secrets.remove(context.accountKey)
            if context.previousLegacyPassword != nil {
                // Also clear any legacy shared slot so nothing is orphaned.
                try secrets.remove(.mailAppPassword)
            }
            return true
        } catch {
            reportRemovedAccountRollbackError(
                baseMessage: Self.keychainMessage(action: "remove", error: error),
                account: account,
                context: context,
                messageSurface: messageSurface
            )
            return false
        }
    }

    private func persistRemovedSavedAccountSettings(
        _ account: SavedMailAccount,
        context: SavedAccountRemovalContext,
        messageSurface: TransientMessageSurface
    ) -> Bool {
        do {
            try persistSettingsSync(context.nextSettings)
            return true
        } catch {
            reportRemovedAccountRollbackError(
                baseMessage: Self.settingsMessage(action: "save", error: error),
                account: account,
                context: context,
                messageSurface: messageSurface
            )
            return false
        }
    }

    private func applyRemovedSavedAccountState(
        _ context: SavedAccountRemovalContext,
        messageSurface: TransientMessageSurface
    ) {
        savedAccounts = context.nextSettings.savedAccounts
        if context.shouldClearCurrentAccount || context.ownsWorkspaceGuidance {
            clearWorkspaceAuthGuidance(for: messageSurface)
        }
        if context.shouldClearCurrentAccount {
            goOfflineAfterRemovingActiveAccount()
        }
    }

    private func purgeRemovedSavedAccountDataIfNeeded(
        _ account: SavedMailAccount,
        context: SavedAccountRemovalContext,
        purgeLocalData: Bool,
        messageSurface: TransientMessageSurface
    ) -> Bool {
        guard purgeLocalData else { return true }
        let wasWatching = context.shouldClearCurrentAccount && watchStatus == .watching
        if context.shouldClearCurrentAccount {
            stopWatching()
        }
        do {
            try purgeLocalMailArtifacts(
                for: account.email,
                includeUnscopedArtifacts: context.shouldClearCurrentAccount
            )
            return true
        } catch {
            if wasWatching {
                startWatchingIfReady()
            }
            setConnectionError("Couldn't erase local mail data. \(Self.message(for: error))", for: messageSurface)
            return false
        }
    }

    private func restoreWatchingAfterPreservedSavedAccountRemovalIfNeeded(_ shouldRestore: Bool) {
        guard shouldRestore else { return }
        startWatchingIfReady()
    }

    private func reportRemovedAccountRollbackError(
        baseMessage: String,
        account: SavedMailAccount,
        context: SavedAccountRemovalContext,
        messageSurface: TransientMessageSurface
    ) {
        setConnectionError(
            removedAccountRollbackMessage(
                baseMessage: baseMessage,
                accountEmail: account.email,
                accountPassword: context.previousAccountPassword,
                legacyPassword: context.previousLegacyPassword
            ),
            for: messageSurface
        )
    }

    private func settingsAfterRemovingSavedAccount(
        _ account: SavedMailAccount,
        clearCurrentAccount: Bool
    ) -> Settings {
        var settings = buildSettings(
            mailEmail: clearCurrentAccount ? "" : nil,
            signaturePolicyOverride: clearCurrentAccount ? SignaturePolicy.default.rawValue : nil,
            signatureTextOverride: clearCurrentAccount ? "" : nil
        )
        if clearCurrentAccount {
            settings.mailHost = Settings.default.mailHost
            settings.mailPort = Settings.default.mailPort
            settings.mailHostGuidanceEmail = nil
            settings.mailHostGuidancePendingEmail = false
        }
        settings.savedAccounts.removeAll { $0.id == account.id }
        return settings
    }

    private func removedAccountRollbackMessage(
        baseMessage: String,
        accountEmail: String,
        accountPassword: String?,
        legacyPassword: String?
    ) -> String {
        var message = baseMessage
        let rollbackError = restoreRemovedAccountSecrets(
            accountEmail: accountEmail,
            accountPassword: accountPassword,
            legacyPassword: legacyPassword
        )
        if let rollbackError {
            message += " " + Self.keychainMessage(action: "restore", error: rollbackError)
        }
        return message
    }

    private func restoreRemovedAccountSecrets(
        accountEmail: String,
        accountPassword: String?,
        legacyPassword: String?
    ) -> Error? {
        do {
            if let accountPassword {
                try secrets.set(accountPassword, for: .mailAppPassword(email: accountEmail))
            }
            if let legacyPassword {
                try secrets.set(legacyPassword, for: .mailAppPassword)
            }
            return nil
        } catch {
            logger.error("Failed to roll back removed mail secret: \(error.localizedDescription)")
            return error
        }
    }

    /// Tears down the active account after it has been removed from the list.
    private func goOfflineAfterRemovingActiveAccount() {
        mailEmail = ""
        mailHost = Settings.default.mailHost
        mailPort = Settings.default.mailPort
        mailHostExplicitlyEditedEmail = nil
        mailHostExplicitlyEditedBeforeEmail = false
        mailAppPassword = ""
        isAccountConnected = false
        clearSignatureForAccountRemoval()
        cancelAllSendCountdowns()
        stopWatching()
        resetMessagePreviewForAccountChange()
    }
}
