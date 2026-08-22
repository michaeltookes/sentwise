import Foundation

/// Session-token minting for `ManagedAccountService` (split out to keep the actor
/// body under the length limit). Clerk rotates the client token on every mint, so
/// mints are serialized and rotated tokens are carefully preserved on failure.
extension ManagedAccountService {

        func beginMintTurn() async {
            guard isMintingSessionToken else {
                isMintingSessionToken = true
                return
            }
            await withCheckedContinuation { continuation in
                mintWaiters.append(continuation)
            }
        }

        func endMintTurn() {
            guard !mintWaiters.isEmpty else {
                isMintingSessionToken = false
                return
            }
            let next = mintWaiters.removeFirst()
            next.resume()
        }

        enum MintCredentialState {
            case current
            case rotated
            case signedOutOrReplaced
        }

        enum MintFailureClientTokenHandling {
            case none
            case pending(ClerkSignInHandle)
            case pendingOAuth(ClerkOAuthHandle)
            case stored(generation: Int)
        }

        func credentialState(generation: Int, sessionID: String, clientToken: String) -> MintCredentialState {
            guard !areStoredCredentialsInvalidated,
                  generation == authenticationGeneration,
                  storedSessionID == sessionID
            else {
                return .signedOutOrReplaced
            }
            return storedClientToken == clientToken ? .current : .rotated
        }

        func mintSessionToken(
            sessionID: String,
            clientToken: String,
            preserveFailureClientToken: MintFailureClientTokenHandling = .none
        ) async throws -> ClerkMintedToken {
            do {
                return try await clerk.mintSessionToken(sessionId: sessionID, clientToken: clientToken)
            } catch ClerkError.http(let status, _, let rotatedClientToken) where status == 401 || status == 404 {
                switch preserveFailureClientToken {
                case .pending, .pendingOAuth:
                    try preserveRotatedClientTokenFromMintFailure(
                        rotatedClientToken,
                        sessionID: sessionID,
                        clientToken: clientToken,
                        handling: preserveFailureClientToken
                    )
                case .none, .stored:
                    break
                }
                throw LLMError.managedNotSignedIn
            } catch let error as ClerkError {
                try preserveRotatedClientTokenFromMintFailure(
                    error.clientToken,
                    sessionID: sessionID,
                    clientToken: clientToken,
                    handling: preserveFailureClientToken
                )
                // Network/transport (or other non-auth) Clerk failure minting a token —
                // surface as a transport error so the user sees the "couldn't reach" message.
                throw LLMError.transport("managed session token request failed")
            }
        }

        func preserveRotatedClientTokenFromMintFailure(
            _ rotatedClientToken: String?,
            sessionID: String,
            clientToken: String,
            handling: MintFailureClientTokenHandling
        ) throws {
            guard let rotatedClientToken, !rotatedClientToken.isEmpty else { return }
            switch handling {
            case .none:
                return
            case .pending(let handle):
                updatePendingSignIn(handle, clientToken: rotatedClientToken)
            case .pendingOAuth(let handle):
                updatePendingOAuthSignIn(handle, clientToken: rotatedClientToken)
            case .stored(let generation):
                guard credentialState(
                    generation: generation,
                    sessionID: sessionID,
                    clientToken: clientToken
                ) == .current else {
                    return
                }
                try persistClientToken(rotatedClientToken)
            }
        }

        var currentCredentialIdentity: String? {
            guard !areStoredCredentialsInvalidated,
                  let sessionID = storedSessionID
            else { return nil }
            return credentialIdentity(generation: authenticationGeneration, sessionID: sessionID)
        }

        func credentialIdentity(generation: Int, sessionID: String) -> String {
            "\(generation):\(sessionID)"
        }
}
