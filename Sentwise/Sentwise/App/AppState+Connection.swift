import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "Connection")

/// Mail-account connect/disconnect on `AppState`. Split out of `AppState` so that
/// file stays within length limits; the verify → persist → adopt flow and its
/// rollback are unchanged.
extension AppState {

    /// Builds credentials from the current inputs.
    var mailCredentials: MailAccountCredentials {
        let email = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return MailAccountCredentials(
            email: email,
            appPassword: MailCredentialPasswordNormalization.normalized(
                mailAppPassword,
                email: email,
                host: host
            ),
            host: host,
            port: mailPort
        )
    }

    /// Tests the mailbox connection and, on success, saves the credentials.
    @discardableResult
    func testConnection() async -> Bool {
        connectionError = nil
        commitMailEmailEditFromUser()

        let credentials = mailCredentials
        return await testConnection(with: credentials) {
            self.isCurrentMailCredentialSnapshot($0)
        }
    }

    /// Tests the mailbox connection from an explicit credential snapshot and, on
    /// success, adopts it as the active account.
    @discardableResult
    func testConnection(
        with credentials: MailAccountCredentials,
        shouldApplyResult: @escaping @MainActor (MailAccountCredentials) -> Bool = { _ in true }
    ) async -> Bool {
        connectionError = nil
        clearWorkspaceAuthGuidance()
        let email = credentials.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = MailAccountCredentials(
            email: email,
            appPassword: MailCredentialPasswordNormalization.normalized(
                credentials.appPassword,
                email: email,
                host: host
            ),
            host: host,
            port: credentials.port
        )
        guard credentials.isComplete else {
            connectionError = "Enter your email address and app password first."
            return false
        }

        isConnecting = true
        defer { isConnecting = false }
        let wasWatching = watchStatus == .watching

        do {
            try await mailProvider.verifyConnection(credentials)
        } catch {
            guard shouldApplyResult(credentials) else { return false }
            connectionError = Self.message(for: error)
            classifyWorkspaceAuthFailure(error, credentials: credentials)
            return false
        }
        guard shouldApplyResult(credentials) else { return false }

        let previousSettings = persistence.loadSettings()
        let previousEmail = previousSettings.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountIdentityChanged = hasAccountIdentityChanged(from: previousEmail, to: credentials.email)
        let requiresTransitionCleanup = !isAccountConnected || accountIdentityChanged
        guard persistVerifiedConnectionTransition(
            credentials,
            previousSettings: previousSettings,
            accountIdentityChanged: accountIdentityChanged,
            requiresTransitionCleanup: requiresTransitionCleanup
        ) else { return false }
        isAccountConnected = true
        if requiresTransitionCleanup {
            // A different or newly reconnected account invalidates any in-flight
            // auto-send countdowns (item 23) and offline-queued dispatches (item 27).
            cancelAllSendCountdowns()
            if wasWatching {
                stopWatching()
                startWatchingIfReady()
            }
        }
        resetMessagePreviewForAccountChange(clearSkippedMessages: requiresTransitionCleanup)
        // Now that mail is connected, catch up any transcript that arrived while
        // the account was disconnected but the folder watcher was already active.
        startTranscriptFolderWatchingIfEnabled()
        logger.info("Mailbox connected")
        return true
    }

    private func hasAccountIdentityChanged(from previousEmail: String, to nextEmail: String) -> Bool {
        guard !previousEmail.isEmpty else { return false }
        return previousEmail.caseInsensitiveCompare(nextEmail) != .orderedSame
    }

    private func isCurrentMailCredentialSnapshot(_ credentials: MailAccountCredentials) -> Bool {
        Self.connectionCredentials(mailCredentials, match: credentials)
    }

    private static func connectionCredentials(
        _ lhs: MailAccountCredentials,
        match rhs: MailAccountCredentials
    ) -> Bool {
        lhs.email.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.email.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            && lhs.appPassword == rhs.appPassword
            && lhs.host.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(rhs.host.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            && lhs.port == rhs.port
    }

    /// Disconnects the mailbox by clearing the stored app password.
    func disconnectMail() {
        connectionError = nil
        clearWorkspaceAuthGuidance()
        guard !isConnecting else {
            logger.info("Disconnect skipped while a connection test is running")
            return
        }
        do {
            try removeLegacyOAuthCredentialsIfPresent()
        } catch {
            connectionError = Self.legacyOAuthCleanupMessage(error: error)
            return
        }

        guard let removedPassword = removeActiveMailPasswordForDisconnect() else { return }
        guard clearQueuedDispatchesBeforeAccountTransition("disconnecting") else {
            appendConnectionRollbackMessage(restoreActiveMailPasswordRemovalMessage(removedPassword))
            return
        }
        mailAppPassword = ""
        markMailHostVerifiedForGuidance()
        isAccountConnected = false
        cancelAllSendCountdowns()
        stopWatching()
        resetMessagePreviewForAccountChange(clearSkippedMessages: false)
        skippedMessages = []
        logger.info("Mailbox disconnected")
    }

    private func clearQueuedDispatchesBeforeAccountTransition(_ action: String) -> Bool {
        do {
            try clearAllOfflineQueueEntriesDurably()
            return true
        } catch {
            connectionError = "Couldn't clear queued drafts before \(action). \(Self.message(for: error))"
            logger.error("Failed to clear queued drafts before \(action, privacy: .public): \(error.localizedDescription)")
            return false
        }
    }

    private func persistVerifiedConnectionTransition(
        _ credentials: MailAccountCredentials,
        previousSettings: Settings,
        accountIdentityChanged: Bool,
        requiresTransitionCleanup: Bool
    ) -> Bool {
        // Per-account key (item 48): writing a second account never overwrites the
        // first account's secret, so switching back to it later needs no re-entry.
        let accountKey = SecretKey.mailAppPassword(email: credentials.email)
        let previousAppPassword: String?
        do {
            previousAppPassword = try secrets.value(for: accountKey)
        } catch {
            connectionError = Self.keychainMessage(action: "read", error: error)
            return false
        }

        do {
            try secrets.set(credentials.appPassword, for: accountKey)
        } catch {
            connectionError = Self.keychainMessage(action: "save", error: error)
            return false
        }

        do {
            try persistVerifiedConnection(credentials, clearSignature: accountIdentityChanged)
        } catch {
            connectionError = failedConnectionPersistMessage(
                error,
                previousSettings: previousSettings,
                previousAppPassword: previousAppPassword,
                accountKey: accountKey
            )
            return false
        }

        let cleanupAction = accountIdentityChanged ? "changing accounts" : "reconnecting"
        guard !requiresTransitionCleanup || clearQueuedDispatchesBeforeAccountTransition(cleanupAction) else {
            appendConnectionRollbackMessage(rollbackVerifiedConnectionTransition(
                to: previousSettings,
                previousAppPassword: previousAppPassword,
                for: accountKey
            ))
            return false
        }
        if accountIdentityChanged {
            clearSignatureForAccountChange()
        }
        return true
    }

    private func failedConnectionPersistMessage(
        _ error: Error,
        previousSettings: Settings,
        previousAppPassword: String?,
        accountKey: SecretKey
    ) -> String {
        let rollbackError = rollbackMailAppPassword(to: previousAppPassword, for: accountKey)
        restoreConnectionSnapshot(settings: previousSettings)
        var message = Self.settingsMessage(action: "save", error: error)
        if let rollbackError {
            message += " " + Self.keychainMessage(action: "restore", error: rollbackError)
        }
        return message
    }

    private func rollbackVerifiedConnectionTransition(
        to previousSettings: Settings,
        previousAppPassword: String?,
        for accountKey: SecretKey
    ) -> String? {
        var messages: [String] = []
        if let rollbackError = rollbackMailAppPassword(to: previousAppPassword, for: accountKey) {
            messages.append(Self.keychainMessage(action: "restore", error: rollbackError))
        }
        do {
            try persistSettingsSync(previousSettings)
        } catch {
            messages.append(Self.settingsMessage(action: "restore", error: error))
        }
        restoreConnectionSnapshot(settings: previousSettings)
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    private func restoreActiveMailPasswordRemovalMessage(_ removal: ActiveMailPasswordRemoval) -> String? {
        guard let rollbackError = restoreActiveMailPasswordRemoval(removal) else { return nil }
        return Self.keychainMessage(action: "restore", error: rollbackError)
    }

    private func appendConnectionRollbackMessage(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        if let connectionError, !connectionError.isEmpty {
            self.connectionError = connectionError + " " + message
        } else {
            connectionError = message
        }
    }
}
