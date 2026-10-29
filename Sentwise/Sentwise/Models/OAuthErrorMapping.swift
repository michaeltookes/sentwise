import Foundation
import SentwiseMail

/// Maps raw OAuth error responses to typed `OAuthError`s (sign-in-first
/// architecture 4.6). Pure functions over strings and numbers, so every row of
/// the table is unit-testable without a network.
enum OAuthErrorMapping {
    /// Where in the flow the error arrived: an `invalid_grant` on the code
    /// exchange means a bad code, on a refresh it means the grant is gone.
    enum Phase: Equatable {
        case exchange
        case refresh
    }

    /// An administrator must approve the app.
    static let adminConsentCodes: Set<Int> = [65001, 90094, 90095]
    /// The user must sign in again (password change, MFA, Conditional Access,
    /// inactivity, removed consent).
    static let reauthenticationCodes: Set<Int> = [50173, 70000, 70008, 50076, 50079, 53003, 50158]

    /// The `AADSTS<digits>` codes found in free text, plus any listed in the
    /// response's `error_codes` array.
    static func aadstsCodes(in text: String?, listed: [Int] = []) -> Set<Int> {
        var codes = Set(listed)
        guard let text else { return codes }
        var rest = Substring(text)
        while let range = rest.range(of: "AADSTS") {
            let digits = rest[range.upperBound...].prefix { $0.isNumber }
            if let code = Int(digits) { codes.insert(code) }
            rest = rest[range.upperBound...]
        }
        return codes
    }

    /// Maps an error from the token endpoint. Anything not in the table stays
    /// `.server`, so unmapped providers and codes behave as before.
    static func tokenEndpointError(
        code: String,
        description: String?,
        errorCodes: [Int] = [],
        phase: Phase,
        tenantID: String? = nil
    ) -> OAuthError {
        let codes = aadstsCodes(in: description, listed: errorCodes)
        if code == "consent_required" || !codes.isDisjoint(with: adminConsentCodes) {
            return .adminConsentRequired(tenantID: tenantID)
        }
        if phase == .refresh,
           code == "invalid_grant" || code == "interaction_required"
            || !codes.isDisjoint(with: reauthenticationCodes) {
            return .reauthenticationRequired
        }
        return .server(code: code, description: description)
    }

    /// Maps an `error` on the loopback redirect. Cancelling stays
    /// `.authorizationDenied`; only the admin-consent signals change.
    static func redirectError(code: String, description: String?, tenantID: String? = nil) -> OAuthError {
        let codes = aadstsCodes(in: description)
        if code == "consent_required" || !codes.isDisjoint(with: adminConsentCodes) {
            return .adminConsentRequired(tenantID: tenantID)
        }
        return .authorizationDenied(code)
    }
}

/// The IMAP-side classification of a rejected XOAUTH2 login (architecture 4.6):
/// a token minted moments ago that the server still refuses is not an expired
/// or revoked grant but a mailbox whose IMAP access an administrator switched off.
enum MailboxProtocolMapping {
    /// A token younger than this that the server rejects points at the mailbox,
    /// not at the token.
    static let freshTokenWindow: TimeInterval = 60

    /// Reclassifies an IMAP `AUTHENTICATE` rejection: `.authenticationFailed`
    /// with a token younger than `freshTokenWindow` becomes
    /// `.mailboxProtocolDisabled(.imap, ...)`. Any other error, or an older
    /// token, is returned unchanged (the grant may simply have expired).
    static func classifyIMAPAuthenticationFailure(_ error: MailError, tokenAge: TimeInterval) -> MailError {
        guard case .authenticationFailed(let detail) = error, tokenAge < freshTokenWindow else { return error }
        return .mailboxProtocolDisabled(.imap, detail)
    }
}
