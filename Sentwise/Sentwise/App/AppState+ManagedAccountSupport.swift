import Foundation

extension AppState {

    func reportManagedErrorIfCurrent(_ message: String, generation: UInt64) {
        guard isCurrentSettingsTransientMessageGeneration(generation) else { return }
        managedError = message
    }

    static func managedMessage(for error: Error) -> String {
        managedClerkMessage(for: error)
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
