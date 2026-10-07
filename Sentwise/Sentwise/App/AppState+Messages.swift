import SentwiseMail
import Foundation

/// Mail/Keychain error-message mapping for `AppState`. Kept in a separate file
/// so `AppState` stays within the file/type length limits.
extension AppState {

    /// Maps an error to a concise, user-facing message.
    static func message(for error: Error) -> String {
        switch error {
        case MailError.incompleteCredentials:
            return "Enter your email address and app password first."
        case MailError.authenticationFailed(let detail):
            return "Sign-in failed — check your email and app password. (\(detail))"
        case MailError.connectionFailed(let detail):
            return "Couldn't reach the mail server. (\(detail))"
        case MailError.commandFailed(let detail):
            return "The mail server rejected a request. (\(detail))"
        case MailError.smtpCommandFailed(_, let message):
            return "The mail server rejected a send request. (\(message))"
        case MailError.sendInterruptedAfterSubmission(let detail):
            return "The connection dropped while sending — the message may already have gone out. "
                + "Check your Sent mail before resending. (\(detail))"
        case MailError.resultTooLarge:
            return "Too many messages matched to list at once. Narrow your search "
                + "(a specific sender, keyword, or date) and try again."
        case KeychainError.unexpectedStatus(let status):
            return "Keychain returned status \(status)."
        case KeychainError.dataEncodingFailed:
            return "Keychain could not encode the app password."
        default:
            return error.localizedDescription
        }
    }

    static func keychainMessage(action: String, error: Error) -> String {
        "Couldn't \(action) the app password in Keychain. \(message(for: error))"
    }

    static func legacyOAuthCleanupMessage(error: Error) -> String {
        "Couldn't remove the legacy Gmail OAuth credentials from Keychain. \(message(for: error))"
    }

    static func settingsMessage(action: String, error: Error) -> String {
        "Couldn't \(action) mailbox settings. \(message(for: error))"
    }

    /// Guidance shown when Test Connection runs with incomplete credentials.
    ///
    /// When the email and app password are both present but the IMAP host is
    /// empty — the case where an unrecognized provider domain couldn't be
    /// auto-filled — the message names the IMAP server and the Advanced
    /// section rather than the already-filled fields (item 109). Otherwise it
    /// falls back to the generic prompt for when the email and/or app password
    /// are the missing fields.
    static func incompleteCredentialsMessage(for credentials: MailAccountCredentials) -> String {
        let hasEmail = !credentials.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPassword = !credentials.appPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasHost = !credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasEmail && hasPassword && !hasHost {
            return "Enter your IMAP server under Advanced (IMAP server). "
                + "Your email provider's domain wasn't recognized, so the server couldn't be filled in automatically."
        }
        return "Enter your email address and app password first."
    }
}
