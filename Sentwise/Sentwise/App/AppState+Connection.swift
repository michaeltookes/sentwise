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
    func testConnection() async {
        connectionError = nil
        commitMailEmailEditFromUser()

        await testConnection(with: mailCredentials)
    }

    /// Tests the mailbox connection from an explicit credential snapshot and, on
    /// success, adopts it as the active account.
    func testConnection(with credentials: MailAccountCredentials) async {
        connectionError = nil
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
            return
        }

        isConnecting = true
        defer { isConnecting = false }
        let wasWatching = watchStatus == .watching

        do {
            try await mailProvider.verifyConnection(credentials)
        } catch {
            connectionError = Self.message(for: error)
            return
        }

        let previousSettings = persistence.loadSettings()
        let accountChanged = !isAccountConnected
            || previousSettings.mailEmail.caseInsensitiveCompare(credentials.email) != .orderedSame
        guard persistVerifiedConnectionTransition(
            credentials,
            previousSettings: previousSettings,
            accountChanged: accountChanged
        ) else { return }
        isAccountConnected = true
        if accountChanged {
            // A different account invalidates any in-flight auto-send countdowns
            // (item 23) and offline-queued dispatches (item 27); neither must fire
            // against the newly connected account.
            cancelAllSendCountdowns()
            if wasWatching {
                stopWatching()
                startWatchingIfReady()
            }
        }
        resetMessagePreviewForAccountChange(clearSkippedMessages: accountChanged)
        // Now that mail is connected, catch up any transcript that arrived while
        // the account was disconnected but the folder watcher was already active.
        startTranscriptFolderWatchingIfEnabled()
        logger.info("Mailbox connected")
    }

    /// Disconnects the mailbox by clearing the stored app password.
    func disconnectMail() {
        connectionError = nil
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
        resetMessagePreviewForAccountChange()
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
        accountChanged: Bool
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
            try persistVerifiedConnection(credentials, clearSignature: accountChanged)
        } catch {
            connectionError = failedConnectionPersistMessage(
                error,
                previousSettings: previousSettings,
                previousAppPassword: previousAppPassword,
                accountKey: accountKey
            )
            return false
        }

        guard !accountChanged || clearQueuedDispatchesBeforeAccountTransition("changing accounts") else {
            appendConnectionRollbackMessage(rollbackVerifiedConnectionTransition(
                to: previousSettings,
                previousAppPassword: previousAppPassword,
                for: accountKey
            ))
            return false
        }
        if accountChanged {
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
