import Foundation
import os

private let signInLogger = Logger(subsystem: DiagnosticLog.subsystem, category: "ManagedSignIn")

/// Email-code completion instrumentation is split from the account actor so each
/// verify/mint/finalize failure has a redaction-safe stage marker without pushing
/// the core service over its lint limits.
extension ManagedAccountService {

    /// Completes sign-in with the OTP code. On success stores the session id and
    /// latest device token after proving the credentials can mint a session token.
    @discardableResult
    func completeSignIn(code: String) async throws -> ManagedAccountSignInResult {
        guard let pending = pendingSignIn else {
            signInLogger.error("Email-code sign-in failed stage=verify reason=no-pending-flow")
            throw ClerkError.malformedResponse("no sign-in in progress")
        }
        let verified: ClerkVerifiedSession
        do {
            verified = try await clerk.verifyEmailCode(
                signInId: pending.signInId,
                code: code,
                clientToken: pending.clientToken,
                flow: pending.flow
            )
        } catch {
            if let clerkError = error as? ClerkError {
                updatePendingSignIn(pending, clientToken: clerkError.clientToken)
            }
            logSignInFailure(stage: "verify", credential: .managedClientToken, error: error)
            throw error
        }

        logSignInSuccess(stage: "verify", credential: .managedClientToken)
        updatePendingSignIn(pending, clientToken: verified.clientToken)
        try requirePendingSignIn(pending, stage: "mint")
        let minted: ClerkMintedToken
        do {
            minted = try await mintSessionToken(
                sessionID: verified.sessionId,
                clientToken: verified.clientToken,
                preserveFailureClientToken: .pending(pending)
            )
        } catch {
            logSignInFailure(stage: "mint", credential: .managedClientToken, error: error)
            throw error
        }
        logSignInSuccess(stage: "mint", credential: .managedClientToken)
        try requirePendingSignIn(pending, stage: "mint")
        updatePendingSignIn(pending, clientToken: minted.clientToken)
        try requirePendingSignIn(pending, stage: "finalize")

        let result = ManagedAccountSignInResult(
            displayIdentifier: verified.identifier,
            accountIdentifier: Self.accountIdentifier(userID: minted.userID, sessionID: verified.sessionId)
        )
        do {
            try finalizeVerifiedSession(sessionID: verified.sessionId, clientToken: minted.clientToken)
        } catch {
            logSignInFailure(stage: "finalize", credential: .managedSessionID, error: error)
            throw error
        }
        logSignInSuccess(stage: "finalize", credential: .managedSessionID)
        return result
    }

    private func requirePendingSignIn(_ pending: ClerkSignInHandle, stage: String) throws {
        guard isPendingSignIn(pending) else {
            signInLogger.error("Email-code sign-in failed stage=\(stage, privacy: .public) reason=cancelled-flow")
            throw ClerkError.malformedResponse("no sign-in in progress")
        }
    }

    private func logSignInSuccess(stage: String, credential: SecretKey) {
        let credentialID = credential.logSafeIdentifier
        signInLogger.info(
            "Sign-in stage=\(stage, privacy: .public) completed key=\(credentialID, privacy: .public)"
        )
    }

    private func logSignInFailure(stage: String, credential: SecretKey, error: Error) {
        let credentialID = credential.logSafeIdentifier
        let errorID = Self.logErrorIdentifier(error)
        signInLogger.error(
            "Sign-in stage=\(stage, privacy: .public) key=\(credentialID, privacy: .public) error=\(errorID, privacy: .public)"
        )
    }

    /// Clerk messages and transport details can contain user input, so unified
    /// logging records only the error family and safe HTTP status.
    private static func logErrorIdentifier(_ error: Error) -> String {
        switch error {
        case ClerkError.transport:
            return "clerk.transport"
        case ClerkError.http(let status, _, _):
            return "clerk.http.\(status)"
        case ClerkError.malformedResponse:
            return "clerk.malformedResponse"
        case ClerkError.notComplete:
            return "clerk.notComplete"
        case ClerkError.emailCodeUnsupported:
            return "clerk.emailCodeUnsupported"
        case ClerkError.accountNotFound:
            return "clerk.accountNotFound"
        default:
            return String(reflecting: type(of: error))
        }
    }
}
