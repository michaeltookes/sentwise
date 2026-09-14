import Foundation
import os

private let revocationLogger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedAccountService")

private struct SignOutInvalidationAttempt {
    let markerPersisted: Bool
    let error: Error?
}

private struct SignOutCredentialCleanup {
    let clientTokenRemoved: Bool
    let sessionIDRemoved: Bool
    let firstError: Error?

    var removedAnyCredential: Bool {
        clientTokenRemoved || sessionIDRemoved
    }
}

struct ManagedAccountSignOutError: Error {
    let underlying: Error
    let didDurablySignOut: Bool
}

extension ManagedAccountSignOutError: LocalizedError {
    var errorDescription: String? {
        underlying.localizedDescription
    }
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
        let hadPersistedInvalidationMarker = areStoredCredentialsInvalidated
            && secrets.hasValue(for: .managedCredentialsInvalidated)
        clearTransientSignOutState()
        let invalidation = persistCredentialInvalidationForSignOutIfNeeded(wasSignedIn: wasSignedIn)
        if let revocation {
            fireServerSessionRevocation(sessionID: revocation.sessionID, clientToken: revocation.clientToken)
        }

        let cleanup = removeStoredManagedCredentials()
        clearPendingOAuthSignInIDBestEffort(context: "after sign-out")
        let result = finishLocalCredentialCleanup(
            cleanup: cleanup,
            invalidation: invalidation,
            hadPersistedInvalidationMarker: hadPersistedInvalidationMarker,
            wasSignedIn: wasSignedIn
        )
        if let firstError = result.error {
            throw ManagedAccountSignOutError(
                underlying: firstError,
                didDurablySignOut: result.didDurablySignOut
            )
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

    private func removeStoredManagedCredentials() -> SignOutCredentialCleanup {
        var clientTokenRemoved = false
        var sessionIDRemoved = false
        var firstError: Error?
        do {
            try secrets.remove(.managedClientToken)
            clientTokenRemoved = true
        } catch {
            firstError = error
        }
        do {
            try secrets.remove(.managedSessionID)
            sessionIDRemoved = true
        } catch {
            firstError = firstError ?? error
        }
        return SignOutCredentialCleanup(
            clientTokenRemoved: clientTokenRemoved,
            sessionIDRemoved: sessionIDRemoved,
            firstError: firstError
        )
    }

    private func finishLocalCredentialCleanup(
        cleanup: SignOutCredentialCleanup,
        invalidation: SignOutInvalidationAttempt,
        hadPersistedInvalidationMarker: Bool,
        wasSignedIn: Bool
    ) -> (error: Error?, didDurablySignOut: Bool) {
        var firstError = cleanup.firstError
        let hasDurableInvalidationMarker = invalidation.markerPersisted || hadPersistedInvalidationMarker
        let durableSignedOutState = hasDurableInvalidationMarker || cleanup.removedAnyCredential
        if durableSignedOutState {
            areStoredCredentialsInvalidated = hasDurableInvalidationMarker && !cleanup.removedAnyCredential
            if wasSignedIn {
                authenticationGeneration &+= 1
            }
        } else if !hasStoredManagedCredential {
            areStoredCredentialsInvalidated = false
        }

        if cleanup.removedAnyCredential {
            clearCredentialInvalidationMarkerBestEffort(context: "after sign-out")
        } else if !durableSignedOutState, let invalidationError = invalidation.error {
            firstError = firstError ?? invalidationError
        }
        clearReauthenticationClientTokenBestEffort(context: "after sign-out")
        return (firstError, durableSignedOutState)
    }
}
