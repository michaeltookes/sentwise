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
    func testConnection(messageSurface: TransientMessageSurface = .shared) async -> Bool {
        setConnectionError(nil, for: messageSurface)
        commitMailEmailEditFromUser()

        let credentials = mailCredentials
        return await testConnection(with: credentials, messageSurface: messageSurface) {
            self.isCurrentMailCredentialSnapshot($0)
        }
    }

    /// Tests the mailbox connection from an explicit credential snapshot and, on
    /// success, adopts it as the active account.
    @discardableResult
    func testConnection(
        with credentials: MailAccountCredentials,
        messageSurface: TransientMessageSurface = .shared,
        shouldApplyResult: @escaping @MainActor (MailAccountCredentials) -> Bool = { _ in true }
    ) async -> Bool {
        setConnectionError(nil, for: messageSurface)
        clearWorkspaceAuthGuidance(for: messageSurface)
        let settingsMessageGeneration = settingsTransientMessageGeneration
        let credentials = normalizedConnectionCredentials(credentials)
        guard credentials.isComplete else {
            setConnectionError("Enter your email address and app password first.", for: messageSurface)
            return false
        }

        isConnecting = true
        defer { isConnecting = false }
        let wasWatching = watchStatus == .watching

        do {
            try await mailProvider.verifyConnection(credentials)
        } catch {
            guard shouldApplyConnectionResult(
                credentials,
                surface: messageSurface,
                generation: settingsMessageGeneration,
                shouldApplyResult: shouldApplyResult
            ) else { return false }
            setConnectionError(Self.message(for: error), for: messageSurface)
            classifyWorkspaceAuthFailure(error, credentials: credentials, messageSurface: messageSurface)
            return false
        }
        guard shouldApplyConnectionResult(
            credentials,
            surface: messageSurface,
            generation: settingsMessageGeneration,
            shouldApplyResult: shouldApplyResult
        ) else { return false }

        let previousSettings = persistence.loadSettings()
        let previousEmail = previousSettings.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountIdentityChanged = hasAccountIdentityChanged(from: previousEmail, to: credentials.email)
        let requiresTransitionCleanup = !isAccountConnected || accountIdentityChanged
        guard persistVerifiedConnectionTransition(
            credentials,
            previousSettings: previousSettings,
            accountIdentityChanged: accountIdentityChanged,
            requiresTransitionCleanup: requiresTransitionCleanup,
            messageSurface: messageSurface
        ) else { return false }
        if messageSurface == .settings {
            setConnectionError(nil, for: .shared)
        }
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

    private func normalizedConnectionCredentials(_ credentials: MailAccountCredentials) -> MailAccountCredentials {
        let email = credentials.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return MailAccountCredentials(
            email: email,
            appPassword: MailCredentialPasswordNormalization.normalized(
                credentials.appPassword,
                email: email,
                host: host
            ),
            host: host,
            port: credentials.port
        )
    }

    private func shouldApplyConnectionResult(
        _ credentials: MailAccountCredentials,
        surface: TransientMessageSurface,
        generation: UInt64,
        shouldApplyResult: @escaping @MainActor (MailAccountCredentials) -> Bool
    ) -> Bool {
        shouldApplyResult(credentials) && isCurrentTransientMessageSurface(surface, generation: generation)
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
    func disconnectMail(messageSurface: TransientMessageSurface = .shared) {
        setConnectionError(nil, for: messageSurface)
        clearWorkspaceAuthGuidance(for: messageSurface)
        guard !isConnecting else {
            logger.info("Disconnect skipped while a connection test is running")
            return
        }
        do {
            try removeLegacyOAuthCredentialsIfPresent()
        } catch {
            setConnectionError(Self.legacyOAuthCleanupMessage(error: error), for: messageSurface)
            return
        }

        guard let removedPassword = removeActiveMailPasswordForDisconnect(messageSurface: messageSurface) else { return }
        guard clearQueuedDispatchesBeforeAccountTransition("disconnecting", messageSurface: messageSurface) else {
            appendConnectionRollbackMessage(
                restoreActiveMailPasswordRemovalMessage(removedPassword),
                messageSurface: messageSurface
            )
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

    private func clearQueuedDispatchesBeforeAccountTransition(
        _ action: String,
        messageSurface: TransientMessageSurface = .shared
    ) -> Bool {
        do {
            try clearAllOfflineQueueEntriesDurably()
            return true
        } catch {
            setConnectionError(
                "Couldn't clear queued drafts before \(action). \(Self.message(for: error))",
                for: messageSurface
            )
            logger.error("Failed to clear queued drafts before \(action, privacy: .public): \(error.localizedDescription)")
            return false
        }
    }

    private func persistVerifiedConnectionTransition(
        _ credentials: MailAccountCredentials,
        previousSettings: Settings,
        accountIdentityChanged: Bool,
        requiresTransitionCleanup: Bool,
        messageSurface: TransientMessageSurface
    ) -> Bool {
        // Per-account key (item 48): writing a second account never overwrites the
        // first account's secret, so switching back to it later needs no re-entry.
        let accountKey = SecretKey.mailAppPassword(email: credentials.email)
        let previousAppPassword: String?
        do {
            previousAppPassword = try secrets.value(for: accountKey)
        } catch {
            setConnectionError(Self.keychainMessage(action: "read", error: error), for: messageSurface)
            return false
        }

        do {
            try secrets.set(credentials.appPassword, for: accountKey)
        } catch {
            setConnectionError(Self.keychainMessage(action: "save", error: error), for: messageSurface)
            return false
        }

        do {
            try persistVerifiedConnection(credentials, clearSignature: accountIdentityChanged)
        } catch {
            setConnectionError(
                failedConnectionPersistMessage(
                    error,
                    previousSettings: previousSettings,
                    previousAppPassword: previousAppPassword,
                    accountKey: accountKey
                ),
                for: messageSurface
            )
            return false
        }

        let cleanupAction = accountIdentityChanged ? "changing accounts" : "reconnecting"
        guard !requiresTransitionCleanup
            || clearQueuedDispatchesBeforeAccountTransition(cleanupAction, messageSurface: messageSurface) else {
            appendConnectionRollbackMessage(
                rollbackVerifiedConnectionTransition(
                    to: previousSettings,
                    previousAppPassword: previousAppPassword,
                    for: accountKey
                ),
                messageSurface: messageSurface
            )
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

    private func appendConnectionRollbackMessage(
        _ message: String?,
        messageSurface: TransientMessageSurface = .shared
    ) {
        guard let message, !message.isEmpty else { return }
        if let connectionError = connectionError(for: messageSurface), !connectionError.isEmpty {
            setConnectionError(connectionError + " " + message, for: messageSurface)
        } else {
            setConnectionError(message, for: messageSurface)
        }
    }
}
