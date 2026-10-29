import Foundation

/// Stateless helpers of `GmailAuthCoordinator` (item 104): the authorized
/// address check, cancellation normalization, and user-facing copy. Kept
/// apart so the state machine stays within its length limits.
extension GmailAuthCoordinator {

    static func authorizedEmail(token: OAuthToken, loginHint: String?, requireHintMatch: Bool) throws -> String {
        guard let email = token.idToken.flatMap(GoogleIDToken.email(fromIDToken:)) else {
            throw GmailAuthError.missingAccountEmail
        }
        if requireHintMatch, let loginHint, !loginHint.isEmpty,
           loginHint.caseInsensitiveCompare(email) != .orderedSame {
            throw GmailAuthError.accountMismatch(expected: loginHint, actual: email)
        }
        return email
    }

    /// Abandoning the flow cancels its task, but a canceled `URLSession`
    /// request (the code exchange) throws `URLError(.cancelled)` rather than
    /// `CancellationError`. Both mean "the user walked away", never a failure.
    static func normalizingCancellation(_ error: Error) -> Error {
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        return error
    }

    // MARK: - Messages

    /// User-facing copy for a failed sign-in.
    static func message(for error: Error) -> String {
        if let error = error as? GmailAuthError { return message(for: error) }
        if let error = error as? OAuthError { return message(for: error) }
        return "Google sign-in failed. \(error.localizedDescription)"
    }

    private static func message(for error: GmailAuthError) -> String {
        switch error {
        case .notConfigured:
            return "Sign in with Google isn't available in this build. Use an app password instead."
        case .reauthorizationRequired, .notConnected:
            return "Your Google sign-in has expired or was revoked. Sign in with Google again."
        case .missingAccountEmail:
            return "Google didn't share which address you signed in with. Please try again."
        case .accountMismatch(let expected, let actual):
            return "You signed in as \(actual), but this account is \(expected). Choose \(expected) on Google's screen."
        case .alreadyInProgress:
            return "A Google sign-in is already open in your browser."
        case .revocationPending:
            return "Sentwise is still disconnecting your previous Google sign-in. Try again in a moment."
        case .superseded:
            return "Your Google sign-in changed while Sentwise was refreshing it. Please try again."
        }
    }

    private static func message(for error: OAuthError) -> String {
        switch error {
        case .authorizationDenied(let reason):
            return reason == "access_denied" ? "Google sign-in was canceled." : "Google sign-in failed (\(reason))."
        case .redirectTimedOut:
            return "Google sign-in timed out. Try again and finish in your browser."
        case .missingRequiredScopes:
            return "Sentwise needs permission to read and send your mail. Sign in again and allow Gmail access."
        case .missingRefreshToken:
            return "Google didn't grant offline access. Sign in again and approve all requested access."
        case .stateMismatch:
            return "The Google sign-in response didn't match this request. Please try again."
        case .server(let code, let description):
            return "Google sign-in failed: \(description ?? code)."
        case .invalidResponse:
            return "Google sign-in returned an unexpected response. Please try again."
        case .temporarilyUnavailable:
            return "Google's sign-in service is temporarily unavailable. Please try again in a few minutes."
        case .adminConsentRequired:
            return "Your organization requires an administrator to approve Sentwise."
        case .reauthenticationRequired:
            return "Your sign-in has expired or was revoked. Sign in again."
        }
    }
}
