import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedAccount")

/// The stage of the managed-inference email-code sign-in flow.
enum ManagedSignInStage: Equatable {
    /// No sign-in in progress — show the email field.
    case idle
    /// A code was emailed — show the code field.
    case codeSent
    /// A browser-based sign-in (Google) is underway — show a "finish in your
    /// browser" panel instead of the form until the callback returns.
    case awaitingBrowser
}

/// Managed-inference account actions on `AppState` (backlog item 56a): the
/// email-code sign-in flow, sign-out, and the launch-state restore. Kept in its own
/// file so `AppState` stays within length limits, mirroring `AppState+LLM`. The
/// launch-time settings migrations live in `AppState+SettingsMigration`.
extension AppState {

    // MARK: - Busy state

    /// Which managed-account action is currently in flight, so only the pressed
    /// button shows a spinner while all of them disable. `nil` = idle.
    enum ManagedBusyAction: Equatable {
        case emailCode, verifyCode, google, oauthCallback, signOut, deleteAccount
    }

    /// True while any managed action is running (drives button disabling).
    var isManagedBusy: Bool { managedBusyAction != nil }

    // MARK: - Sign-in flow

    /// Sends a one-time code to the email in `managedEmailInput` and advances the
    /// flow to the code-entry stage. In Prowl hunt mode this is a deterministic,
    /// fully-offline fake: it advances to the code-entry stage without any network
    /// or Clerk call, so hunts can drive the sign-in UI end-to-end (item 70).
    /// `isHuntMode` is injectable so unit tests can exercise the fake path.
    func startManagedSignIn(
        activatesManagedProvider: Bool = true,
        isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled,
        messageSurface: TransientMessageSurface = .shared
    ) async {
        setManagedError(nil, for: messageSurface)
        pendingManagedSignInMessageSurface = messageSurface
        didDeleteManagedAccount = false
        let email = managedEmailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), email.count >= 3 else {
            setManagedError("Enter your email address.", for: messageSurface)
            return
        }
        let settingsMessageGeneration = settingsTransientMessageGeneration

        if isHuntMode {
            // Deterministic offline fake: advance to code entry, no network.
            pendingManagedSignInEmail = email
            pendingManagedSignInActivatesProvider = activatesManagedProvider
            managedEmailInput = email
            managedSignInStage = .codeSent
            return
        }

        managedBusyAction = .emailCode
        defer { managedBusyAction = nil }
        pendingManagedSignInEmail = nil
        do {
            try await managedAccount.startSignIn(email: email)
            pendingManagedSignInEmail = email
            pendingManagedSignInActivatesProvider = activatesManagedProvider
            managedEmailInput = email
            managedSignInStage = .codeSent
        } catch {
            pendingManagedSignInActivatesProvider = true
            reportManagedErrorIfCurrent(
                Self.managedMessage(for: error),
                generation: settingsMessageGeneration,
                surface: messageSurface
            )
        }
    }

    /// Verifies the code in `managedCodeInput`, completing sign-in. By default the
    /// managed provider becomes the connected provider and drafting is enabled; the
    /// Workspace guidance can sign in only to scope notification-interest capture.
    /// In Prowl hunt mode this is a deterministic, fully-offline fake: any non-empty
    /// code completes to the signed-in fixture account without any network or Clerk
    /// call (item 70). `isHuntMode` is injectable so unit tests can exercise it.
    func verifyManagedCode(
        isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled,
        messageSurface: TransientMessageSurface = .shared
    ) async {
        setManagedError(nil, for: messageSurface)
        let activatesManagedProvider = pendingManagedSignInActivatesProvider
        if isHuntMode {
            // Deterministic offline fake: the button completes to the fixture account.
            // This avoids macOS TextField commit timing making Prowl hunts flaky.
            let signedInEmail = pendingManagedSignInEmail
                ?? managedEmailInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if activatesManagedProvider, llmProviderKind != .managed {
                selectLLMProvider(.managed, messageSurface: messageSurface)
            }
            finalizeManagedSignIn(email: signedInEmail, accountID: "hunt-email:\(signedInEmail)")
            return
        }

        let code = managedCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            setManagedError("Enter the code from your email.", for: messageSurface)
            return
        }
        let settingsMessageGeneration = settingsTransientMessageGeneration

        managedBusyAction = .verifyCode
        defer { managedBusyAction = nil }
        let result: ManagedAccountSignInResult
        do {
            result = try await managedAccount.completeSignIn(code: code)
        } catch {
            reportManagedErrorIfCurrent(
                Self.managedMessage(for: error),
                generation: settingsMessageGeneration,
                surface: messageSurface
            )
            return
        }

        // Sign-in succeeded: record the account tied to the pending Clerk flow.
        let signedInEmail = pendingManagedSignInEmail
            ?? managedEmailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if activatesManagedProvider, llmProviderKind != .managed {
            selectLLMProvider(.managed, messageSurface: messageSurface)
        }
        finalizeManagedSignIn(email: signedInEmail, accountID: result.accountIdentifier)
    }

    func resetManagedSignInFlow(
        messageSurface: TransientMessageSurface = .shared,
        resetPendingMessageSurface: Bool = true
    ) {
        pendingManagedSignInEmail = nil
        if resetPendingMessageSurface {
            pendingManagedSignInMessageSurface = .shared
        }
        managedSignInStage = .idle
        managedCodeInput = ""
        setManagedError(nil, for: messageSurface)
        pendingManagedSignInActivatesProvider = true
    }

    func cancelManagedSignInFlow(messageSurface: TransientMessageSurface = .shared) async {
        let wasAwaitingBrowser = managedSignInStage == .awaitingBrowser
        let canceledSurface = pendingManagedSignInMessageSurface
        await managedAccount.cancelSignIn()
        resetManagedSignInFlow(messageSurface: messageSurface, resetPendingMessageSurface: false)
        if wasAwaitingBrowser {
            clearManagedOAuthMessageSurfaceBestEffort()
            clearManagedOAuthFlowIDBestEffort()
            persistCanceledManagedOAuthCallbackSurfaceBestEffort(canceledSurface)
        }
    }

    /// Signs out of the managed account: clears stored tokens and connected state.
    /// Local mail data and voice profile are untouched.
    func signOutManaged(messageSurface: TransientMessageSurface = .shared) async {
        setManagedError(nil, for: messageSurface)
        let settingsMessageGeneration = settingsTransientMessageGeneration
        managedBusyAction = .signOut
        defer { managedBusyAction = nil }
        do {
            try await managedAccount.signOut()
        } catch let error as ManagedAccountSignOutError {
            handleManagedSignOutError(
                error,
                generation: settingsMessageGeneration,
                messageSurface: messageSurface
            )
            return
        } catch {
            if await managedAccount.isSignedIn {
                reportManagedErrorIfCurrent(
                    Self.managedMessage(for: error),
                    generation: settingsMessageGeneration,
                    surface: messageSurface
                )
                return
            }
            applyManagedSignedOutState(clearEmailInput: true, messageSurface: messageSurface)
            reportManagedErrorIfCurrent(
                Self.managedMessage(for: error),
                generation: settingsMessageGeneration,
                surface: messageSurface
            )
            saveSettings()
            return
        }
        applyManagedSignedOutState(clearEmailInput: true, messageSurface: messageSurface)
        saveSettings()
    }

    /// Deletes the Sentwise account server-side (`DELETE /v1/me`, item 73), then
    /// clears or durably invalidates the managed credentials locally. Returns
    /// `true` when the account was deleted and local credentials cannot restore it.
    /// Local mail, voice profile, drafts, and settings on this Mac are untouched
    /// unless `purgeLocalData` is set, in which case the account-scoped mail
    /// artifacts are also purged after a successful deletion (item 96).
    /// On failure the account is kept and `managedError` carries the mapped message.
    /// In Prowl hunt mode this is a
    /// deterministic, zero-network no-op that reports success without tearing down
    /// the signed-in fixture (so the hunt can keep walking). `isHuntMode` is
    /// injectable for unit tests.
    @discardableResult
    func deleteManagedAccount(
        purgeLocalData: Bool = false,
        isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled,
        messageSurface: TransientMessageSurface = .shared
    ) async -> Bool {
        setManagedError(nil, for: messageSurface)
        let settingsMessageGeneration = settingsTransientMessageGeneration
        if isHuntMode {
            // Offline no-op: the confirm button "works" without teardown.
            return true
        }

        managedBusyAction = .deleteAccount
        defer { managedBusyAction = nil }
        if didDeleteManagedAccount && !isManagedSignedIn {
            return retryManagedLocalMailPurgeAfterDeleted(
                purgeLocalData,
                generation: settingsMessageGeneration,
                messageSurface: messageSurface
            )
        }

        do {
            try await llm.deleteManagedAccount()
        } catch {
            await reconcileManagedAccountState(after: error, provider: .managed, messageSurface: messageSurface)
            reportManagedErrorIfCurrent(
                Self.managedMessage(for: error),
                generation: settingsMessageGeneration,
                surface: messageSurface
            )
            return false
        }

        // Deleted server-side: either remove local credentials or leave a durable
        // invalidation marker so a later launch cannot restore the deleted account.
        do {
            try await managedAccount.signOut()
        } catch let error as ManagedAccountSignOutError where error.didDurablySignOut {
            logger.error(
                "Managed account deletion cleanup finished with a durable local sign-out: \(error.localizedDescription)"
            )
        } catch {
            do {
                try await managedAccount.invalidateStoredCredentialsForDeletedAccount()
            } catch {
                reportManagedErrorIfCurrent(
                    "Your account was deleted, but Sentwise couldn't clear local credentials. "
                        + Self.managedMessage(for: error),
                    generation: settingsMessageGeneration,
                    surface: messageSurface
                )
                return false
            }
        }
        applyManagedSignedOutState(clearEmailInput: true, messageSurface: messageSurface)
        didDeleteManagedAccount = true
        // Server-side deletion removes the Sentwise account; the local mailbox
        // cache is separate. If the user asked, purge the account-scoped mail
        // artifacts on this Mac too (item 96) — the confirmation states plainly
        // that this is what stays local otherwise.
        guard purgeLocalMailDataAfterManagedDeleteIfNeeded(
            purgeLocalData,
            generation: settingsMessageGeneration,
            messageSurface: messageSurface
        ) else { return false }
        saveSettings()
        return true
    }

    func purgeLocalMailDataAfterManagedDeleteIfNeeded(
        _ purgeLocalData: Bool,
        generation: UInt64,
        messageSurface: TransientMessageSurface
    ) -> Bool {
        guard purgeLocalData else { return true }
        let wasWatching = watchStatus == .watching
        stopWatching()
        do {
            if let account = normalizedConnectedAccountEmail {
                try purgeLocalMailArtifacts(for: account, includeUnscopedArtifacts: true)
            } else {
                try purgeAllLocalMailArtifacts()
            }
            resetMessagePreviewForAccountChange(clearSkippedMessages: false)
            if wasWatching {
                startWatchingIfReady()
            }
            return true
        } catch {
            if wasWatching { startWatchingIfReady() }
            reportManagedErrorIfCurrent(
                "Your account was deleted, but Sentwise couldn't erase local mail data. "
                    + Self.managedMessage(for: error),
                generation: generation,
                surface: messageSurface
            )
            return false
        }
    }

    var managedAccountDisplayEmail: String {
        managedAccountStatus?.email ?? managedAccountEmail
    }

    // MARK: - Launch state (item 56a)

    /// What the LLM fields should look like at launch for the managed provider.
    /// When the account credentials are present, managed is treated as verified
    /// with its default model regardless of any stale custom model in settings.
    struct ManagedLaunchState: Equatable {
        let provider: LLMProviderKind
        let hasCredentials: Bool
        let restoreVerification: Bool
        let llmModel: String
        let verifiedLLMModel: String
        /// The stored API key for the resolved provider (empty for managed/none).
        let apiKey: String
    }

    static func managedLaunchState(settings: Settings, secrets: SecretStore) -> ManagedLaunchState {
        // Parked 2026-09-16 (item 100): an unrecognized persisted provider resolves
        // to managed, the only shipped path. Genuine pre-release non-managed values
        // are reset to managed by `migratedBYOKParkedSettings` before launch reads them.
        let provider = LLMProviderKind(rawValue: settings.llmProvider) ?? .managed
        let clerkCutoverPending = settings.schemaVersion < Settings.clerkProductionCutoverSchemaVersion
        let hasCurrentClerkCredentialEnvironment =
            hasCurrentManagedClerkCredentialEnvironmentMarker(secrets: secrets)
        let hasInvalidatedCredentials = secrets.hasValue(for: .managedCredentialsInvalidated)
        let hasCredentials = !clerkCutoverPending
            && hasCurrentClerkCredentialEnvironment
            && !hasInvalidatedCredentials
            && secrets.hasValue(for: .managedClientToken)
            && secrets.hasValue(for: .managedSessionID)
        let restore = provider == .managed && hasCredentials
        let apiKey = storedLLMAPIKey(
            provider: provider,
            baseURL: provider.supportsCustomBaseURL ? settings.llmBaseURL : nil,
            secrets: secrets
        )
        return ManagedLaunchState(
            provider: provider,
            hasCredentials: hasCredentials,
            restoreVerification: restore,
            llmModel: restore ? "" : settings.llmModel,
            verifiedLLMModel: restore ? provider.defaultModel : settings.llmVerifiedModel,
            apiKey: apiKey
        )
    }

    func restoreManagedAccountLaunchIdentity(_ launch: ManagedLaunchState, settings: Settings) {
        guard launch.hasCredentials else {
            managedAccountEmail = ""
            managedAccountID = ""
            isManagedSignedIn = false
            return
        }
        managedAccountEmail = settings.managedAccountEmail
        managedAccountID = settings.managedAccountID
        isManagedSignedIn = true
    }

    /// Writes the restored managed verification back to disk when launch changed
    /// what was loaded, so the next launch doesn't redo the restoration.
    func persistRestoredManagedVerificationIfNeeded(_ launch: ManagedLaunchState, loadedFrom settings: Settings) {
        guard launch.restoreVerification,
              settings.llmModel != launch.llmModel || settings.llmVerifiedModel != launch.verifiedLLMModel
        else { return }
        do {
            try persistSettingsSync(buildSettings())
        } catch {
            logger.error("Failed to persist restored managed verification: \(error.localizedDescription)")
        }
    }

    // MARK: - Watcher reauth (item 56a)

    /// After a successful managed refresh, restart a watcher that auth/licensing paused.
    func resumeInboxWatchingAfterManagedReauthenticationIfNeeded() {
        resumeInboxWatchingAfterProviderRecoveryIfNeeded()
    }

    func shouldResumeAfterManagedReauthentication(error: Error, provider: LLMProviderKind?) -> Bool {
        guard provider == .managed else { return false }
        switch error {
        case LLMError.managedNotSignedIn, LLMError.managedTrialExpired:
            return true
        default:
            return false
        }
    }

}
