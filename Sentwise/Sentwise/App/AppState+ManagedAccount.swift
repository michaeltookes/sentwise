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
/// email-code sign-in flow, sign-out, and the one-time settings migration onto
/// the managed provider. Kept in its own file so `AppState` stays within length
/// limits, mirroring `AppState+LLM`.
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
    /// Local mail, voice profile, drafts, and settings on this Mac are untouched.
    /// On failure the account is kept and `managedError` carries the mapped message.
    /// In Prowl hunt mode this is a
    /// deterministic, zero-network no-op that reports success without tearing down
    /// the signed-in fixture (so the hunt can keep walking). `isHuntMode` is
    /// injectable for unit tests.
    @discardableResult
    func deleteManagedAccount(
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
        do {
            try await llm.deleteManagedAccount()
        } catch {
            await reconcileManagedAccountState(after: error, provider: .managed)
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
        saveSettings()
        return true
    }

    private func applyManagedSignedOutState(
        clearEmailInput: Bool,
        messageSurface: TransientMessageSurface = .shared
    ) {
        clearManagedQuotaCache()
        isManagedSignedIn = false
        managedAccountEmail = ""
        managedAccountID = ""
        if clearEmailInput {
            managedEmailInput = ""
        }
        managedCodeInput = ""
        pendingManagedSignInEmail = nil
        pendingManagedSignInMessageSurface = .shared
        clearManagedOAuthMessageSurfaceBestEffort()
        clearManagedOAuthFlowIDBestEffort()
        clearCanceledManagedOAuthCallbackSurfaceBestEffort()
        pendingManagedSignInActivatesProvider = true
        managedSignInStage = .idle
        googleOAuthInterestRegistered = false
        setGoogleOAuthInterestError(nil, for: messageSurface)
        if llmProviderKind == .managed {
            verifiedLLMModel = ""
            refreshLLMConnectionStatus()
            resetDraftPreviewForLLMChange()
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
        let provider = LLMProviderKind(rawValue: settings.llmProvider) ?? .anthropic
        let hasInvalidatedCredentials = secrets.hasValue(for: .managedCredentialsInvalidated)
        let hasCredentials = !hasInvalidatedCredentials
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
        guard resumeWatchingAfterManagedReauth else { return }
        guard watchStatus == .paused || watchStatus == .idle else { return }
        guard canWatch else { return }
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

    // MARK: - Migration (item 56a)

    /// Runs all launch-time settings migrations in order: the saved-accounts move
    /// (item 48), the managed-inference default (item 56a), then the additive
    /// signature schema (item 24). Only the terminal step persists, so a launch
    /// that migrates writes the fully-migrated settings exactly once, at the
    /// current schema version. Keeps `AppState.init` short by chaining here.
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
        return migratedSignatureSettings(
            managedMigrated,
            originalSchemaVersion: loaded.schemaVersion,
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

        let provider = LLMProviderKind(rawValue: settings.llmProvider) ?? .anthropic
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

    /// Terminal launch migration (item 24). The signature fields are purely
    /// additive — older files decode them to defaults — so this step carries no
    /// field logic; it only advances the schema version to the current one and
    /// persists the fully-migrated settings exactly once. Runs last so a single
    /// write records the final version regardless of which earlier steps changed.
    static func migratedSignatureSettings(
        _ settings: Settings,
        originalSchemaVersion: Int,
        persistence: PersistenceProvider
    ) -> Settings {
        guard originalSchemaVersion < Settings.currentSchemaVersion else { return settings }
        var migrated = settings
        migrated.schemaVersion = Settings.currentSchemaVersion
        if migrated != settings {
            do {
                try persistence.saveSettingsSync(migrated)
            } catch {
                logger.error("Failed to persist signature migration: \(error.localizedDescription)")
            }
        }
        return migrated
    }

    /// If the managed account actor invalidated stored credentials while minting a
    /// session token, mirror that state back into the published AppState flags.
    /// Returns `true` when this call changed auth or licensing state, so callers
    /// whose staleness guards would otherwise swallow the error can still surface
    /// it — the configuration changed *because of* this failure, not under the user.
    @discardableResult
    func reconcileManagedAccountState(after error: Error, provider: LLMProviderKind) async -> Bool {
        guard provider == .managed else { return false }
        if case LLMError.managedTrialExpired = error {
            supersedeInFlightManagedAccountStatusRefreshes()
            recordManagedEntitlementBlockedSnapshot()
            managedAccountStatus = nil
            managedAccountStatusIsFresh = false
            scheduleManagedAccountStatusRefreshRetryAfterFailure()
            return true
        }
        guard case LLMError.managedNotSignedIn = error else { return false }
        guard !(await managedAccount.isSignedIn) else { return false }

        applyManagedSignedOutState(clearEmailInput: false)
        saveSettings()
        return true
    }
}
