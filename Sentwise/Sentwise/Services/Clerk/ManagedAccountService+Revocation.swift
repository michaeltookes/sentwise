import Foundation
import os

private let revocationLogger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedAccountService")

private struct SignOutInvalidationAttempt {
    let markerPersisted: Bool
    let error: Error?
}

private struct SignOutCredentialSnapshot {
    let clientToken: String?
    let sessionID: String?
    let firstReadError: Error?

    var hasCompleteCredentialPair: Bool {
        clientToken != nil && sessionID != nil
    }

    var mayHaveStoredCredential: Bool {
        clientToken != nil || sessionID != nil || firstReadError != nil
    }
}

private struct SignOutCredentialCleanup {
    let clientTokenRemoved: Bool
    let sessionIDRemoved: Bool
    let firstError: Error?

    var removedAllCredentials: Bool {
        clientTokenRemoved && sessionIDRemoved
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
    /// local cleanup runs immediately; only the fire-and-forget revocation waits
    /// for an in-flight token mint so it can use Clerk's latest rotated client
    /// token without letting a failed or slow network call fail sign-out
    /// (security finding A-L3).
    func signOut(revokeServerSession: Bool = !ProwlHuntRuntime.current.isEnabled) async throws {
        let credentialSnapshot = storedCredentialSnapshotForSignOut()
        let wasSignedIn = !areStoredCredentialsInvalidated && credentialSnapshot.hasCompleteCredentialPair
        let shouldInvalidateStoredCredentials = credentialSnapshot.mayHaveStoredCredential
        let revocation = serverSessionRevocationRequest(
            revokeServerSession: revokeServerSession,
            wasSignedIn: wasSignedIn,
            credentialSnapshot: credentialSnapshot
        )
        let hadPersistedInvalidationMarker = areStoredCredentialsInvalidated
            && secrets.hasValue(for: .managedCredentialsInvalidated)
        let revocationRequestID: UUID?
        if let revocation {
            revocationRequestID = scheduleServerSessionRevocation(
                sessionID: revocation.sessionID,
                clientToken: revocation.clientToken,
                generation: revocation.generation
            )
        } else {
            revocationRequestID = nil
        }
        clearTransientSignOutState()
        let invalidation = persistCredentialInvalidationForSignOutIfNeeded(
            shouldInvalidateStoredCredentials: shouldInvalidateStoredCredentials
        )

        let cleanup = removeStoredManagedCredentials()
        clearPendingOAuthSignInIDBestEffort(context: "after sign-out")
        let result = finishLocalCredentialCleanup(
            cleanup: cleanup,
            invalidation: invalidation,
            hadPersistedInvalidationMarker: hadPersistedInvalidationMarker,
            invalidatedStoredCredentials: shouldInvalidateStoredCredentials
        )
        if !result.didDurablySignOut, let revocationRequestID {
            cancelServerSessionRevocation(requestID: revocationRequestID)
        }
        if let firstError = result.error {
            throw ManagedAccountSignOutError(
                underlying: firstError,
                didDurablySignOut: result.didDurablySignOut
            )
        }
    }

    func updatePendingServerSessionRevocations(
        generation: Int,
        sessionID: String,
        originalClientToken: String,
        clientToken: String
    ) {
        guard !clientToken.isEmpty else { return }
        for (requestID, revocation) in pendingServerSessionRevocations
        where revocation.generation == generation
            && revocation.sessionID == sessionID
            && revocation.originalClientToken == originalClientToken {
            pendingServerSessionRevocations[requestID]?.clientToken = clientToken
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

    private func scheduleServerSessionRevocation(
        sessionID: String,
        clientToken: String,
        generation: Int
    ) -> UUID {
        let requestID = UUID()
        pendingServerSessionRevocations[requestID] = (
            sessionID: sessionID,
            generation: generation,
            originalClientToken: clientToken,
            clientToken: clientToken
        )
        Task { await self.firePendingServerSessionRevocation(requestID) }
        return requestID
    }

    private func cancelServerSessionRevocation(requestID: UUID) {
        pendingServerSessionRevocations[requestID] = nil
    }

    private func firePendingServerSessionRevocation(_ requestID: UUID) async {
        await beginMintTurn()
        defer { endMintTurn() }
        guard let revocation = pendingServerSessionRevocations.removeValue(forKey: requestID) else { return }
        fireServerSessionRevocation(sessionID: revocation.sessionID, clientToken: revocation.clientToken)
    }

    private func serverSessionRevocationRequest(
        revokeServerSession: Bool,
        wasSignedIn: Bool,
        credentialSnapshot: SignOutCredentialSnapshot
    ) -> (sessionID: String, clientToken: String, generation: Int)? {
        guard revokeServerSession,
              wasSignedIn,
              let sessionID = credentialSnapshot.sessionID,
              let clientToken = credentialSnapshot.clientToken,
              !clientToken.isEmpty
        else { return nil }
        return (sessionID, clientToken, authenticationGeneration)
    }

    private func clearTransientSignOutState() {
        pendingSignIn = nil
        pendingOAuthSignIn = nil
        reauthenticationClientToken = nil
    }

    private func persistCredentialInvalidationForSignOutIfNeeded(
        shouldInvalidateStoredCredentials: Bool
    ) -> SignOutInvalidationAttempt {
        guard shouldInvalidateStoredCredentials else {
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

    private func storedCredentialSnapshotForSignOut() -> SignOutCredentialSnapshot {
        let clientToken = storedCredentialValueForSignOut(.managedClientToken)
        let sessionID = storedCredentialValueForSignOut(.managedSessionID)
        return SignOutCredentialSnapshot(
            clientToken: clientToken.value,
            sessionID: sessionID.value,
            firstReadError: clientToken.error ?? sessionID.error
        )
    }

    private func storedCredentialValueForSignOut(_ key: SecretKey) -> (value: String?, error: Error?) {
        do {
            let value = try secrets.value(for: key)
            return ((value?.isEmpty == false) ? value : nil, nil)
        } catch {
            return (nil, error)
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
        invalidatedStoredCredentials: Bool
    ) -> (error: Error?, didDurablySignOut: Bool) {
        var firstError = cleanup.firstError
        let hasDurableInvalidationMarker = invalidation.markerPersisted || hadPersistedInvalidationMarker
        let durableSignedOutState = hasDurableInvalidationMarker || cleanup.sessionIDRemoved
        if durableSignedOutState {
            areStoredCredentialsInvalidated = hasDurableInvalidationMarker && !cleanup.removedAllCredentials
            if invalidatedStoredCredentials {
                authenticationGeneration &+= 1
            }
        } else if !hasStoredManagedCredential {
            areStoredCredentialsInvalidated = false
        }

        if cleanup.removedAllCredentials {
            clearCredentialInvalidationMarkerBestEffort(context: "after sign-out")
        } else if !durableSignedOutState, let invalidationError = invalidation.error {
            firstError = firstError ?? invalidationError
        }
        clearReauthenticationClientTokenBestEffort(context: "after sign-out")
        return (firstError, durableSignedOutState)
    }
}
