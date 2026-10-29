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

    // TODO(T31-10): placeholder consent copy; the ui-designer and owner approve the final wording.
    static let consentHeading = "Before you continue"
    // TODO(T31-10): placeholder consent copy; final wording pending owner approval.
    static let workAccountNote = "Your IT administrator may need to approve Sentwise for a work or school account."
    // TODO(T31-10): placeholder consent copy; final wording pending owner approval.
    static let consentSummary = "Sentwise will read your inbox on this Mac and send mail you approve. "
        + "Microsoft will ask you to allow mail access."

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
    /// The app-password form is expanded (it is the only path, or no provider leads).
    var appPasswordExpanded: Bool

    static func make(
        email: String,
        host: String,
        isGoogleAvailable: Bool,
        isMicrosoftConfigured: Bool
    ) -> MailConnectLayout {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailKind = EmailProviderKind.forEmail(email)
        let hostKind = trimmedHost.isEmpty ? nil : EmailProviderKind.forHost(trimmedHost)
        let isMicrosoft = emailKind == .microsoft || hostKind == .microsoft
        let google = MailConnectMethod.recommended(
            email: email, host: host, isGoogleSignInAvailable: isGoogleAvailable
        ) == .googleSignIn
        let microsoft = isMicrosoft && isMicrosoftConfigured
        return MailConnectLayout(
            showsGoogle: google && !isMicrosoft,
            showsMicrosoft: microsoft,
            showsMicrosoftNotConfigured: isMicrosoft && !isMicrosoftConfigured,
            appPasswordExpanded: !(google && !isMicrosoft) && !microsoft
        )
    }
}
