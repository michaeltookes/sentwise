import Foundation

extension AppState {

    @discardableResult
    func reportManagedErrorIfCurrent(
        _ message: String,
        generation: UInt64,
        surface: TransientMessageSurface = .shared
    ) -> Bool {
        guard isCurrentTransientMessageSurface(surface, generation: generation) else { return false }
        setManagedError(message, for: surface)
        return true
    }

    func updateManagedEmailInputFromUser(
        _ value: String,
        messageSurface: TransientMessageSurface = .shared
    ) {
        managedEmailInput = value
        setManagedError(nil, for: messageSurface)
    }

    func updateManagedCodeInputFromUser(
        _ value: String,
        messageSurface: TransientMessageSurface = .shared
    ) {
        managedCodeInput = value
        setManagedError(nil, for: messageSurface)
    }

    func handleManagedSignOutError(
        _ error: ManagedAccountSignOutError,
        generation: UInt64,
        messageSurface: TransientMessageSurface
    ) {
        if error.didDurablySignOut {
            applyManagedSignedOutState(clearEmailInput: true, messageSurface: messageSurface)
            reportManagedErrorIfCurrent(
                Self.managedMessage(for: error),
                generation: generation,
                surface: messageSurface
            )
            saveSettings()
            return
        }
        reportManagedErrorIfCurrent(
            Self.managedMessage(for: error),
            generation: generation,
            surface: messageSurface
        )
    }

    /// If the managed account actor invalidated stored credentials while minting a
    /// session token, mirror that state back into the published AppState flags.
    /// Returns `true` when this call changed auth or licensing state, so callers
    /// whose staleness guards would otherwise swallow the error can still surface
    /// it — the configuration changed *because of* this failure, not under the user.
    @discardableResult
    func reconcileManagedAccountState(
        after error: Error,
        provider: LLMProviderKind,
        messageSurface: TransientMessageSurface = .shared
    ) async -> Bool {
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

        applyManagedSignedOutState(clearEmailInput: false, messageSurface: messageSurface)
        saveSettings()
        return true
    }

    func applyManagedSignedOutState(
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

    static func managedMessage(for error: Error) -> String {
        if let error = error as? ManagedAccountSignOutError {
            return managedMessage(for: error.underlying)
        }
        return managedClerkMessage(for: error)
            ?? managedLLMMessage(for: error)
            ?? managedKeychainMessage(for: error)
            ?? error.localizedDescription
    }

    private static func managedClerkMessage(for error: Error) -> String? {
        switch error {
        case ClerkError.transport:
            return "Couldn't reach Sentwise sign-in. Check your connection and try again."
        case ClerkError.http(_, let message, _):
            return message ?? "Sign-in failed. Please try again."
        case ClerkError.notComplete(_, let missingFields, _) where !missingFields.isEmpty:
            return "Sign-up couldn't finish: the account service still requires "
                + missingFields.joined(separator: ", ")
                + ". This is a Sentwise configuration issue, not your code — please contact support."
        case ClerkError.notComplete:
            return "That code didn't complete sign-in. Request a new code and try again."
        case ClerkError.emailCodeUnsupported:
            return "This account can't sign in with an email code."
        case ClerkError.malformedResponse:
            return "Unexpected response from sign-in. Please try again."
        default:
            return nil
        }
    }

    private static func managedLLMMessage(for error: Error) -> String? {
        switch error {
        case LLMError.transport:
            return "Couldn't reach Sentwise sign-in. Check your connection and try again."
        case LLMError.managedNotSignedIn:
            return "Sign-in didn't stick. Please try again."
        case LLMError.managedAccountDeletionFailed(let message):
            return message
        case LLMError.http(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            return "Sentwise account service returned HTTP \(status). Please try again."
        case LLMError.invalidResponse(let detail):
            return "Unexpected response from Sentwise account service. Please try again. (\(detail))"
        default:
            return nil
        }
    }

    private static func managedKeychainMessage(for error: Error) -> String? {
        switch error {
        case KeychainError.unexpectedStatus(let status):
            return "Couldn't update Sentwise AI credentials in Keychain. Keychain returned status \(status)."
        case KeychainError.dataEncodingFailed:
            return "Couldn't update Sentwise AI credentials in Keychain."
        default:
            return nil
        }
    }
}
