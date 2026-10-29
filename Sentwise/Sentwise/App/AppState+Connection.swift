import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "Connection")

/// Mail-account connect/disconnect on `AppState`. Split out of `AppState` so that
/// file stays within length limits; the verify → persist → adopt flow and its
/// rollback are unchanged.
extension AppState {

    /// Builds credentials from the current inputs.
    var mailCredentials: MailAccountCredentials {
        let email = mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = MailAccountCredentials(
            email: email,
            appPassword: MailCredentialPasswordNormalization.normalized(
                mailAppPassword,
                email: email,
                host: host
            ),
            host: host,
            port: mailPort
        )
        // Carry the saved account's SMTP overrides and discovered folder names.
        let key = SavedMailAccount.normalizedEmail(email)
        guard let saved = savedAccounts.first(where: { $0.id == key }) else { return base }
        return saved.applyingTransport(to: base)
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
        await testConnection(
            with: credentials,
            messageSurface: messageSurface,
            attempt: beginMailConnectionAttempt(),
            shouldApplyResult: shouldApplyResult
        )
    }

    /// The verification itself, under an attempt from `beginMailConnectionAttempt()`
    /// (the Google path passes the attempt it began before opening the browser).
    func testConnection(
        with credentials: MailAccountCredentials,
        messageSurface: TransientMessageSurface,
        attempt: UInt64,
        shouldApplyResult callerShouldApplyResult: @escaping @MainActor (MailAccountCredentials) -> Bool
    ) async -> Bool {
        let shouldApplyResult = guardedByMailConnectionAttempt(attempt, callerShouldApplyResult)
        setConnectionError(nil, for: messageSurface)
        clearWorkspaceAuthGuidance(for: messageSurface)
        let settingsMessageGeneration = settingsTransientMessageGeneration
        var credentials = normalizedConnectionCredentials(credentials)
        guard credentials.isComplete else {
            setConnectionError(Self.incompleteCredentialsMessage(for: credentials), for: messageSurface); return false
        }
        // Load the persisted (actually-connected) account and apply the tier gate
        // in one step; the form's `mailEmail` may already show the account being
        // typed, so the count keys off persisted settings, not the form (item 99).
        guard let previousSettings = connectionGatePassed(
            newEmail: credentials.email, messageSurface: messageSurface
        ) else { return false }

        isConnecting = true // a superseded attempt leaves the busy flag to its replacement
        defer { if isCurrentMailConnectionAttempt(attempt) { isConnecting = false } }
        // The previously focused account, so a switch keeps it connected in the
        // background rather than disconnecting it (item 99).
        let previousFocused = previousFocusedSnapshot(from: previousSettings)

        do {
            // One session verifies and resolves the special-folder names (T31-8);
            // a failed LIST only leaves the host defaults in place.
            credentials.discoveredNaming = try await mailProvider.verifyAndDiscover(credentials) ?? credentials.discoveredNaming
            try await probeMicrosoftSubmission(credentials) // item 31, T31-7
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

        let previousEmail = previousSettings.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountIdentityChanged = hasAccountIdentityChanged(from: previousEmail, to: credentials.email)
        let requiresTransitionCleanup = !isAccountConnected || accountIdentityChanged
        let shouldResetBrowser = requiresTransitionCleanup || browserNeedsResetForFocusedEndpointChange(
            previousSettings: previousSettings, credentials: credentials)
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
            applyConnectionTransitionCleanup(
                previousFocused: previousFocused,
                newFocusedEmail: credentials.email
            )
        }
        // A no-op retest must not invalidate in-flight browser body/draft actions;
        // reset only when the effective mailbox/endpoint actually changed.
        resetAfterConnectionSuccess(clearSkippedMessages: requiresTransitionCleanup, resetBrowser: shouldResetBrowser)
        // Now that mail is connected, catch up any transcript that arrived while
        // the account was disconnected but the folder watcher was already active.
        startTranscriptFolderWatchingIfEnabled()
        logger.info("Mailbox connected")
        return true
    }

    private func resetAfterConnectionSuccess(clearSkippedMessages: Bool, resetBrowser: Bool) {
        guard resetBrowser else {
            resetRecentMessagePreviewForConnectionRetest()
            return
        }
        resetMessagePreviewForAccountChange(clearSkippedMessages: clearSkippedMessages, resetBrowser: true)
    }

    private func hasAccountIdentityChanged(from previousEmail: String, to nextEmail: String) -> Bool {
        guard !previousEmail.isEmpty else { return false }
        return previousEmail.caseInsensitiveCompare(nextEmail) != .orderedSame
    }

    private func browserNeedsResetForFocusedEndpointChange(
        previousSettings: Settings,
        credentials: MailAccountCredentials
    ) -> Bool {
        let previousEmail = SavedMailAccount.normalizedEmail(previousSettings.mailEmail)
        guard !previousEmail.isEmpty,
              previousEmail == SavedMailAccount.normalizedEmail(credentials.email) else {
            return false
        }
        if let browserAccount = browser.accountEmail,
           SavedMailAccount.normalizedEmail(browserAccount) != previousEmail {
            return false
        }
        let previousHost = previousSettings.mailHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextHost = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return previousHost.caseInsensitiveCompare(nextHost) != .orderedSame
            || previousSettings.mailPort != credentials.port
    }

    private func normalizedConnectionCredentials(_ credentials: MailAccountCredentials) -> MailAccountCredentials {
        let email = credentials.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Copy so explicit SMTP overrides, OAuth and discovered names survive;
        // only the trimmed IMAP identity fields change.
        var result = credentials
        let smtpWasDerived = credentials.smtpHost
            == MailAccountCredentials.derivedSMTPHost(from: credentials.host)
        result.email = email
        result.host = host
        result.appPassword = MailCredentialPasswordNormalization.normalized(
            credentials.appPassword,
            email: email,
            host: host
        )
        if smtpWasDerived { result.smtpHost = MailAccountCredentials.derivedSMTPHost(from: host) }
        return result
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

    /// Disconnects the mailbox by clearing the stored app password. When
    /// `purgeLocalData` is set (the user chose "Disconnect & erase local data" in
    /// the confirmation), the account-scoped mail artifacts are purged before the
    /// irreversible credential/state removal so a failed erase leaves the account
    /// connected and retryable (item 96).
    func disconnectMail(
        purgeLocalData: Bool = false,
        messageSurface: TransientMessageSurface = .shared
    ) {
        setConnectionError(nil, for: messageSurface)
        clearWorkspaceAuthGuidance(for: messageSurface)
        guard !isConnecting else {
            logger.info("Disconnect skipped while a connection test is running")
            return
        }
        // Browser sign-in and code exchange precede isConnecting. Supersede
        // their callbacks before removing credentials so they cannot reconnect.
        _ = beginMailConnectionAttempt()
        do {
            try removeLegacyOAuthCredentialsIfPresent()
        } catch {
            setConnectionError(Self.legacyOAuthCleanupMessage(error: error), for: messageSurface)
            return
        }

        let disconnectedAccountEmail = mailEmail
        let wasWatching = watchStatus == .watching
        if purgeLocalData {
            stopWatching()
            do {
                try purgeLocalMailArtifacts(for: disconnectedAccountEmail, includeUnscopedArtifacts: true)
            } catch {
                setConnectionError("Couldn't erase local mail data. \(Self.message(for: error))", for: messageSurface)
                restoreWatchingAfterPreservedDisconnectIfNeeded(wasWatching)
                return
            }
        }
        // The Google token goes first and is rolled back with the rest (item 104).
        guard let googleRemoval = takeGoogleTokenForDisconnect(
            email: disconnectedAccountEmail, messageSurface: messageSurface
        ) else {
            restoreWatchingAfterPreservedDisconnectIfNeeded(purgeLocalData && wasWatching)
            return
        }
        guard let removedPassword = removeActiveMailPasswordForDisconnect(messageSurface: messageSurface) else {
            rollBack(googleRemoval)
            restoreWatchingAfterPreservedDisconnectIfNeeded(purgeLocalData && wasWatching)
            return
        }
        let disconnectedAccount = SavedMailAccount.normalizedEmail(disconnectedAccountEmail)
        guard clearQueuedDispatchesBeforeAccountTransition(
            "disconnecting",
            disconnectedAccounts: [disconnectedAccount],
            includeUnscoped: true,
            messageSurface: messageSurface
        ) else {
            appendConnectionRollbackMessage(
                restoreActiveMailPasswordRemovalMessage(removedPassword),
                messageSurface: messageSurface
            )
            rollBack(googleRemoval)
            restoreWatchingAfterPreservedDisconnectIfNeeded(purgeLocalData && wasWatching)
            return
        }
        mailAppPassword = ""
        complete(googleRemoval)
        markMailHostVerifiedForGuidance()
        isAccountConnected = false
        stopWatching()
        resetMessagePreviewForAccountChange(clearSkippedMessages: false)
        skippedMessages = []
        logger.info("Mailbox disconnected")
    }

    private func restoreWatchingAfterPreservedDisconnectIfNeeded(_ shouldRestore: Bool) {
        guard shouldRestore else { return }
        startWatchingIfReady()
    }

    private func clearQueuedDispatchesBeforeAccountTransition(
        _ action: String,
        disconnectedAccounts: Set<String>? = nil,
        includeUnscoped: Bool = true,
        messageSurface: TransientMessageSurface = .shared
    ) -> Bool {
        do {
            if let disconnectedAccounts {
                try clearOfflineQueueEntriesDurably(
                    disconnectedAccounts: disconnectedAccounts,
                    includeUnscoped: includeUnscoped
                )
            } else {
                try clearAllOfflineQueueEntriesDurably()
            }
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

        // Switching this mailbox from Google sign-in to an app password (item 104):
        // the token goes first and is rolled back if any later step fails.
        guard let googleRemoval = takeGoogleTokenForSwitch(
            email: credentials.email, previousSecret: previousAppPassword,
            newSecret: credentials.appPassword, messageSurface: messageSurface
        ) else { return false }
        do {
            try secrets.set(credentials.appPassword, for: accountKey)
        } catch {
            setConnectionError(Self.keychainMessage(action: "save", error: error), for: messageSurface)
            rollBack(googleRemoval)
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
            rollBack(googleRemoval)
            return false
        }

        let cleanupAction = accountIdentityChanged ? "changing accounts" : "reconnecting"
        guard !requiresTransitionCleanup
            || accountIdentityChanged
            || clearQueuedDispatchesBeforeAccountTransition(cleanupAction, messageSurface: messageSurface) else {
            appendConnectionRollbackMessage(
                rollbackVerifiedConnectionTransition(
                    to: previousSettings,
                    previousAppPassword: previousAppPassword,
                    for: accountKey
                ),
                messageSurface: messageSurface
            )
            rollBack(googleRemoval)
            return false
        }
        if accountIdentityChanged {
            clearSignatureForAccountChange()
        }
        complete(googleRemoval)
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
