import Foundation
import os

private let revocationLogger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedAccountService")

private struct SignOutInvalidationAttempt {
    let markerPersisted: Bool
    let error: Error?
}

extension ManagedAccountService {
    /// Signs out: best-effort revokes the Clerk session server-side, then clears
    /// the stored device token and session id. Local mail data is untouched.
    ///
    /// `revokeServerSession` defaults to off during Prowl hunts and test runs,
    /// which run fully offline; production sign-outs revoke by default. The
    /// revocation is fire-and-forget after any in-flight token mint finishes, so
    /// it uses Clerk's latest rotated client token without letting a failed or slow
    /// network call fail the local sign-out (security finding A-L3).
    func signOut(revokeServerSession: Bool = !ProwlHuntRuntime.current.isEnabled) async throws {
        let serializedRevocation = await beginRevocationMintTurnIfNeeded(revokeServerSession)
        defer { endRevocationMintTurnIfNeeded(serializedRevocation) }

        let wasSignedIn = isSignedIn
        let revocation = serverSessionRevocationRequest(
            revokeServerSession: revokeServerSession,
            wasSignedIn: wasSignedIn
        )
        clearTransientSignOutState()
        let invalidation = persistCredentialInvalidationForSignOutIfNeeded(wasSignedIn: wasSignedIn)
        if let revocation {
            fireServerSessionRevocation(sessionID: revocation.sessionID, clientToken: revocation.clientToken)
        }

        var firstError = removeStoredManagedCredentials()
        clearPendingOAuthSignInIDBestEffort(context: "after sign-out")
        firstError = finishLocalCredentialCleanup(
            firstError: firstError,
            invalidation: invalidation,
            wasSignedIn: wasSignedIn
        )
        if let firstError {
            throw firstError
        }
    }

    /// Fires a best-effort server-side revocation of the Clerk session and returns
    /// immediately (security finding A-L3). The network call runs detached, off the
    /// actor, so a failed or slow revocation can never block or fail local
    /// sign-out; all errors are swallowed and logged only.
    func fireServerSessionRevocation(sessionID: String, clientToken: String) {
        let clerk = self.clerk
        Task.detached {
            do {
                let response = try await clerk.revokeSession(sessionId: sessionID, clientToken: clientToken)
                if !response.isSuccess {
                    revocationLogger.error(
                        "Clerk session revocation returned HTTP \(response.statusCode, privacy: .public)"
                    )
                }
            } catch {
                revocationLogger.error(
                    "Clerk session revocation failed: \(String(describing: error), privacy: .private)"
                )
            }
        }
    }

    private func beginRevocationMintTurnIfNeeded(_ revokeServerSession: Bool) async -> Bool {
        guard revokeServerSession, isSignedIn else { return false }
        await beginMintTurn()
        return true
    }

    private func endRevocationMintTurnIfNeeded(_ shouldEnd: Bool) {
        guard shouldEnd else { return }
        endMintTurn()
    }

    private func serverSessionRevocationRequest(
        revokeServerSession: Bool,
        wasSignedIn: Bool
    ) -> (sessionID: String, clientToken: String)? {
        guard revokeServerSession,
              wasSignedIn,
              let sessionID = storedSessionID,
              let clientToken = storedClientToken,
              !clientToken.isEmpty
        else { return nil }
        return (sessionID, clientToken)
    }

    private func clearTransientSignOutState() {
        pendingSignIn = nil
        pendingOAuthSignIn = nil
        reauthenticationClientToken = nil
    }

    private func persistCredentialInvalidationForSignOutIfNeeded(
        wasSignedIn: Bool
    ) -> SignOutInvalidationAttempt {
        guard wasSignedIn else {
            return SignOutInvalidationAttempt(markerPersisted: false, error: nil)
        }
        do {
            try secrets.set(Self.invalidatedCredentialsMarkerValue, for: .managedCredentialsInvalidated)
            return SignOutInvalidationAttempt(markerPersisted: true, error: nil)
        } catch {
            revocationLogger.error(
                "Failed to persist managed credential invalidation marker before sign-out: \(error.localizedDescription)"
            )
            return SignOutInvalidationAttempt(markerPersisted: false, error: error)
        }
    }

    private func removeStoredManagedCredentials() -> Error? {
        var firstError: Error?
        do {
            try secrets.remove(.managedClientToken)
        } catch {
            firstError = error
        }
        do {
            try secrets.remove(.managedSessionID)
        } catch {
            firstError = firstError ?? error
        }
        return firstError
    }

    private func finishLocalCredentialCleanup(
        firstError: Error?,
        invalidation: SignOutInvalidationAttempt,
        wasSignedIn: Bool
    ) -> Error? {
        var firstError = firstError
        let hasCompleteCredentialPair = storedClientToken != nil && storedSessionID != nil
        let durableSignedOutState = invalidation.markerPersisted || !hasCompleteCredentialPair
        if durableSignedOutState {
            areStoredCredentialsInvalidated = invalidation.markerPersisted && hasStoredManagedCredential
            if wasSignedIn {
                authenticationGeneration &+= 1
            }
        } else {
            areStoredCredentialsInvalidated = false
        }

        if !hasStoredManagedCredential {
            areStoredCredentialsInvalidated = false
            clearCredentialInvalidationMarkerBestEffort(context: "after sign-out")
        } else if !durableSignedOutState, let invalidationError = invalidation.error {
            firstError = firstError ?? invalidationError
        }
        clearReauthenticationClientTokenBestEffort(context: "after sign-out")
        return firstError
    }
}
