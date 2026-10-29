import Foundation
import SentwiseMail

/// Copy and view state for "Sign in with Microsoft" (item 31, T31-5), kept as
/// pure values so the screens' states are unit-testable. Strings follow the UX
/// review in docs/requirements/sign-in-first.md. Nothing here ever carries a
/// raw AADSTS code, tenant id, or token: those stay out of user-visible and
/// accessibility text.
enum MicrosoftSignInCopy {
    static let heading = "Connect your inbox"
    static let signInTitle = "Continue with Microsoft"
    static let reauthenticateTitle = "Sign in with Microsoft Again"
    static let signInHint = "Opens your browser to connect this mailbox"
    static let opening = "Opening Microsoft in your browser…"
    static let waitingForBrowser = "Finish signing in with Microsoft in your browser."
    static let exchanging = "Sign-in complete. Connecting your mailbox…"
    static let checking = "Sign-in complete. Checking mail and sending access…"
    static let cancelled = "Microsoft sign-in was cancelled."
    static let noMailAccess = "Microsoft did not grant mail access. Try again and allow mail access."
    static let offline = "You're offline. Connect to the internet, then try again."
    static let notResponding = "Microsoft is not responding. Sentwise will try again."
    static let notVerified = "Sign-in could not be verified. Try again."
    static let adminApproval = "Your organization requires an administrator to approve Sentwise."
    static let copyAdminNote = "Copy a Note for Your IT Admin"
    static let chooseAnotherAccount = "Choose Another Account"
    static let adminNoteCopied = "Note copied."
    static let notConfigured = "Sign in with Microsoft isn't available in this build. Use an app password instead."

    // Consent block shown under "Continue with Microsoft" before the browser
    // opens (T31-10; docs/design/t31-10-microsoft-consent-copy.md). Claims stay
    // inside the requested scopes: IMAP.AccessAsUser.All (read mail, save
    // drafts), SMTP.Send (send what the user approves), offline_access (stay
    // signed in), openid/profile/email (the address). Never say mail does not
    // leave the Mac: drafting sends the needed content to the drafting service.
    static let consentHeading = "Before you continue"
    static let consentSummary = "Microsoft will ask you to let Sentwise read your mail, save drafts, "
        + "and send messages you approve, and to keep this Mac signed in."
    static let consentPrivacy = "Mail is read on this Mac. Only the content needed to draft a reply goes to "
        + "the Sentwise drafting service. Your sign-in is kept in this Mac's Keychain and is never sent to "
        + "Sentwise servers."
    static let consentRevoke = "You can remove Sentwise's access at any time in your Microsoft account."
    static let workAccountNote = "For a work or school account, your IT administrator may need to approve "
        + "Sentwise first."

    /// The consent block as VoiceOver reads it: one element, sentences in order.
    static func consentAccessibilityText(showsWorkAccountNote: Bool) -> String {
        var parts = [consentHeading + ".", consentSummary, consentPrivacy]
        if showsWorkAccountNote { parts.append(workAccountNote) }
        parts.append(consentRevoke)
        return parts.joined(separator: " ")
    }

    static func connected(_ address: String) -> String { "Connected as \(address) with Microsoft" }
    static func reauthenticate(_ address: String) -> String {
        "Sign in with Microsoft again to keep \(address) connected."
    }

    static let imapOff = "IMAP access is off for this mailbox. "
        + "Your administrator needs to enable IMAP before Sentwise can connect."
    static let smtpOff = "Sending is off for this mailbox. "
        + "Your administrator needs to enable SMTP AUTH before Sentwise can connect."

    static func protocolDisabledMessage(_ proto: MailProtocol) -> String {
        proto == .imap ? imapOff : smtpOff
    }

    /// User-facing text for a failed Microsoft sign-in or connect step.
    static func message(for error: Error) -> String {
        if let error = error as? OAuthError { return message(forOAuth: error) }
        if let error = error as? GmailAuthError { return message(forAuth: error) }
        if let error = error as? MailError, case .mailboxProtocolDisabled(let proto, _) = error {
            return protocolDisabledMessage(proto)
        }
        if (error as? URLError)?.code == .notConnectedToInternet { return offline }
        return notVerified
    }

    private static func message(forOAuth error: OAuthError) -> String {
        switch error {
        case .authorizationDenied(let reason):
            return reason == "access_denied" ? cancelled : notVerified
        case .missingRequiredScopes:
            return noMailAccess
        case .adminConsentRequired:
            return adminApproval
        case .reauthenticationRequired:
            return "Your Microsoft sign-in has expired. Sign in with Microsoft again."
        case .temporarilyUnavailable:
            return notResponding
        case .redirectTimedOut:
            return "Microsoft sign-in timed out. Try again and finish in your browser."
        default:
            return notVerified
        }
    }

    private static func message(forAuth error: GmailAuthError) -> String {
        switch error {
        case .notConfigured: return notConfigured
        case .accountMismatch(let expected, _):
            return "Choose \(expected) on Microsoft's screen to keep this mailbox connected."
        case .alreadyInProgress: return waitingForBrowser
        default: return notVerified
        }
    }

    /// Whether `error` is the "an administrator must approve Sentwise" state.
    static func isAdminApproval(_ error: Error) -> Bool {
        if case OAuthError.adminConsentRequired = error { return true }
        return false
    }
}

/// What the Microsoft block on the connect screen shows.
enum MicrosoftSignInViewState: Equatable {
    /// This build has no Microsoft client id: a calm note, app password stays.
    case notConfigured
    /// Ready to sign in; `showsWorkAccountNote` adds the consent note.
    case ready(showsWorkAccountNote: Bool)
    /// A saved mailbox whose grant expired or was revoked.
    case reauthenticate(address: String)
    case waitingForBrowser
    case checking
    /// An administrator must approve Sentwise before this organization can sign in.
    case consentRequired
    /// IMAP or SMTP AUTH is switched off for the mailbox; the admin note applies.
    case protocolDisabled(MailProtocol)
    case failed(String)

    var isInProgress: Bool { self == .waitingForBrowser || self == .checking }

    static func make(
        isConfigured: Bool,
        phase: GmailAuthPhase,
        isVerifying: Bool,
        reauthenticateAddress: String? = nil,
        failure: Error? = nil
    ) -> MicrosoftSignInViewState {
        guard isConfigured else { return .notConfigured }
        switch phase {
        case .awaitingBrowser: return .waitingForBrowser
        case .exchangingCode: return .checking
        case .idle, .failed: break
        }
        if isVerifying { return .checking }
        if let failure {
            return MicrosoftSignInCopy.isAdminApproval(failure)
                ? .consentRequired
                : .failed(MicrosoftSignInCopy.message(for: failure))
        }
        if let address = reauthenticateAddress, !address.isEmpty { return .reauthenticate(address: address) }
        return .ready(showsWorkAccountNote: true)
    }
}

/// Which sign-in options the connect chooser shows for what has been typed.
struct MailConnectLayout: Equatable {
    var showsGoogle: Bool
    var showsMicrosoft: Bool
    /// Microsoft mailbox typed but this build has no Microsoft client id.
    var showsMicrosoftNotConfigured: Bool
    /// The Microsoft option is listed before Google (detection only orders).
    var microsoftLeads: Bool
    /// The app-password form is expanded (it is the only path).
    var appPasswordExpanded: Bool

    /// Both configured providers stay selectable; the typed address or host
    /// only decides which leads. A recognized non-OAuth provider (Yahoo,
    /// iCloud, ...) keeps the app-password path alone.
    static func make(
        email: String,
        host: String,
        isGoogleAvailable: Bool,
        isMicrosoftConfigured: Bool,
        isMicrosoft365Detected: Bool = false
    ) -> MailConnectLayout {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailKind = EmailProviderKind.forEmail(email)
        let hostKind = trimmedHost.isEmpty ? nil : EmailProviderKind.forHost(trimmedHost)
        let isMicrosoft = emailKind == .microsoft || hostKind == .microsoft || isMicrosoft365Detected
        let isOtherKnownProvider = [emailKind, hostKind].contains { $0 != nil && $0 != .gmail && $0 != .microsoft }
        let eligible = !isOtherKnownProvider
        let google = isGoogleAvailable && eligible
        let microsoft = isMicrosoftConfigured && eligible
        return MailConnectLayout(
            showsGoogle: google,
            showsMicrosoft: microsoft,
            showsMicrosoftNotConfigured: isMicrosoft && !isMicrosoftConfigured,
            microsoftLeads: isMicrosoft && microsoft,
            appPasswordExpanded: !google && !microsoft
        )
    }
}
