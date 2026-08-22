import Foundation

/// Google (OAuth) sign-in for the managed-inference account (item 59). Split from
/// `ManagedAccountService.swift` to keep the actor body within the length limit;
/// the members it reaches (`pendingOAuthSignIn`, the client-token persistence and
/// mint helpers, `finalizeVerifiedSession`) are module-internal for that reason.
extension ManagedAccountService {

    /// Begins a Google sign-in and returns the Clerk-hosted URL to open in the
    /// browser. The rotated device token is persisted immediately (like the
    /// email-code flow) so a redirect that arrives after a relaunch still lines up.
    func startGoogleSignIn(redirectURL: String) async throws -> URL {
        let existingClientToken = signInClientTokenForCurrentCredentialState()
        clearPendingSignInHandles()
        let handle: ClerkOAuthHandle
        do {
            handle = try await clerk.startOAuthSignIn(
                strategy: "oauth_google",
                redirectURL: redirectURL,
                clientToken: existingClientToken
            )
        } catch let error as ClerkError {
            persistClientTokenBestEffort(error.clientToken, context: "after failed oauth start")
            throw error
        }
        persistClientTokenBestEffort(handle.clientToken, context: "after starting oauth")
        pendingOAuthSignIn = handle
        persistPendingOAuthSignInIDBestEffort(handle.signInId, context: "after starting oauth")
        return handle.externalRedirectURL
    }

    /// Completes a Google sign-in from the browser redirect's rotating-token
    /// nonce. Returns the account email when Clerk includes it, so the UI can show
    /// "Connected as …". Mirrors `completeSignIn`'s mint-and-persist tail.
    @discardableResult
    func completeGoogleSignIn(rotatingTokenNonce: String) async throws -> String? {
        guard let pending = pendingOAuthSignInHandle() else {
            throw ClerkError.malformedResponse("no oauth sign-in in progress")
        }
        let verified: ClerkVerifiedSession
        do {
            verified = try await clerk.completeOAuthSignIn(
                signInId: pending.signInId,
                rotatingTokenNonce: rotatingTokenNonce,
                clientToken: pending.clientToken
            )
        } catch let error as ClerkError {
            updatePendingOAuthSignIn(pending, clientToken: error.clientToken)
            throw error
        }
        updatePendingOAuthSignIn(pending, clientToken: verified.clientToken)
        guard isPendingOAuthSignIn(pending) else {
            throw ClerkError.malformedResponse("no oauth sign-in in progress")
        }
        let minted = try await mintSessionToken(
            sessionID: verified.sessionId,
            clientToken: verified.clientToken,
            preserveFailureClientToken: .pendingOAuth(pending)
        )
        guard isPendingOAuthSignIn(pending) else {
            throw ClerkError.malformedResponse("no oauth sign-in in progress")
        }
        updatePendingOAuthSignIn(pending, clientToken: minted.clientToken)
        try finalizeVerifiedSession(sessionID: verified.sessionId, clientToken: minted.clientToken)
        return verified.identifier
    }
}
