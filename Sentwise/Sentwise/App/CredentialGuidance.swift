import Foundation

/// Provider-specific instructions for creating the app-specific credential IMAP
/// requires, shown on the connect screen (item 43). Non-Gmail users (AT&T,
/// Yahoo, iCloud) otherwise hit Gmail-only copy and have to hunt through their
/// provider's help pages.
struct CredentialGuidance: Equatable {
    /// Human name of the provider, e.g. "AT&T", "Gmail".
    let providerName: String
    /// What the provider calls the credential, e.g. "Secure Mail Key",
    /// "app password", "app-specific password".
    let credentialName: String
    /// Ordered, plain-language steps to obtain the credential.
    let steps: [String]
    /// A deep link to the provider's credential page, when one is stable.
    let url: URL?
    /// One line disambiguating this provider's credential from the other
    /// grouped-code-string app passwords users confuse it with — most often
    /// Apple vs Google, since both look like `xxxx xxxx xxxx xxxx`. `nil` for
    /// the generic fallback, which isn't tied to a specific provider.
    let appPasswordDistinction: String?
    /// Custom note for providers whose normal-password behavior varies.
    private let passwordNoteOverride: String?

    init(
        providerName: String,
        credentialName: String,
        steps: [String],
        url: URL?,
        appPasswordDistinction: String? = nil,
        passwordNoteOverride: String? = nil
    ) {
        self.providerName = providerName
        self.credentialName = credentialName
        self.steps = steps
        self.url = url
        self.appPasswordDistinction = appPasswordDistinction
        self.passwordNoteOverride = passwordNoteOverride
    }

    /// The disclosure label, phrased around the provider's own credential name
    /// so AT&T users see "Secure Mail Key", not "app password".
    var title: String {
        "Getting your \(credentialName)"
    }

    /// The point recognized providers share and users most often miss: the
    /// normal account password does not work over IMAP.
    var passwordWontWorkNote: String {
        if let passwordNoteOverride = passwordNoteOverride {
            return passwordNoteOverride
        }

        return "Your normal \(providerName) password won't work here — you need "
            + "\(Self.article(for: credentialName)) \(credentialName)."
    }

    /// Guidance for an email address, always returning something usable: a
    /// recognized provider's specific steps, a provider fallback from the IMAP
    /// host for custom domains, or generic advice for the rest.
    static func forEmail(
        _ email: String,
        explicitHostFallback host: String? = nil
    ) -> CredentialGuidance {
        if let kind = EmailProviderKind.forEmail(email) {
            return forKind(kind)
        }
        guard EmailProviderKind.domain(of: email) != nil,
              let kind = host.flatMap(EmailProviderKind.forHost) else {
            return .generic
        }
        return forKind(kind)
    }

    static func forKind(_ kind: EmailProviderKind) -> CredentialGuidance {
        switch kind {
        case .gmail: return gmailGuidance
        case .att: return attGuidance
        case .yahoo: return yahooGuidance
        case .aol: return aolGuidance
        case .icloud: return iCloudGuidance
        case .microsoft: return microsoftGuidance
        }
    }

    static let gmailGuidance = CredentialGuidance(
        providerName: "Gmail",
        credentialName: "app password",
        steps: [
            "Turn on 2-Step Verification in your Google Account — app passwords require it.",
            "Go to myaccount.google.com → Security → App passwords.",
            "Create a password for Mail, then paste the 16-character password here."
        ],
        url: URL(string: "https://myaccount.google.com/apppasswords"),
        appPasswordDistinction: "Make sure this is a Google app password from your "
            + "Google Account — not an Apple/iCloud app-specific password. Both look "
            + "like a grouped 16-character code."
    )

    static let attGuidance = CredentialGuidance(
        providerName: "AT&T",
        credentialName: "Secure Mail Key",
        steps: [
            "Sign in at signin.att.net.",
            "Go to Profile → Sign-in info → Manage secure mail keys.",
            "Select the email address you entered, then Add secure mail key.",
            "Copy the key and paste it here."
        ],
        url: URL(string: "https://signin.att.net"),
        appPasswordDistinction: "Make sure this is an AT&T Secure Mail Key from "
            + "signin.att.net — not an Apple or Google app password."
    )

    static let yahooGuidance = CredentialGuidance(
        providerName: "Yahoo",
        credentialName: "app password",
        steps: [
            "Sign in at account.yahoo.com → Account security.",
            "Choose Generate app password (or Manage app passwords), name it, and generate.",
            "Copy the password and paste it here."
        ],
        url: URL(string: "https://login.yahoo.com/account/security"),
        appPasswordDistinction: "Make sure this is a Yahoo app password from your "
            + "Yahoo account — not an Apple or Google app password."
    )

    static let aolGuidance = CredentialGuidance(
        providerName: "AOL",
        credentialName: "app password",
        steps: [
            "Sign in at login.aol.com → Account security.",
            "Choose Generate app password (or Manage app passwords).",
            "Generate one for Mail, then paste it here."
        ],
        url: URL(string: "https://login.aol.com/account/security"),
        appPasswordDistinction: "Make sure this is an AOL app password from your "
            + "AOL account — not an Apple or Google app password."
    )

    static let iCloudGuidance = CredentialGuidance(
        providerName: "iCloud",
        credentialName: "app-specific password",
        steps: [
            "Sign in at appleid.apple.com.",
            "Enable two-factor authentication if needed, then go to "
                + "Sign-In and Security → App-Specific Passwords.",
            "Create one for Sentwise, then paste it here."
        ],
        url: URL(string: "https://appleid.apple.com"),
        appPasswordDistinction: "Make sure this is an Apple app-specific password from "
            + "appleid.apple.com — not a Google app password. Both look like a grouped "
            + "16-character code."
    )

    /// Microsoft sign-in is the primary path (OAuth); this is the app-password
    /// fallback for personal accounts that have two-step verification on.
    static let microsoftGuidance = CredentialGuidance(
        providerName: "Microsoft",
        credentialName: "app password",
        steps: [
            "Sign in at account.microsoft.com → Security → Advanced security options.",
            "Turn on two-step verification if needed, then choose Create a new app password.",
            "Copy the password and paste it here."
        ],
        url: URL(string: "https://account.microsoft.com/security"),
        appPasswordDistinction: "Make sure this is a Microsoft app password from your "
            + "Microsoft account — not an Apple or Google app password. Work or school "
            + "accounts sign in with Microsoft instead."
    )

    /// Fallback for unrecognized domains. IMAP password requirements vary, so
    /// keep this conditional instead of claiming every provider needs a separate
    /// app-specific credential.
    static let generic = CredentialGuidance(
        providerName: "your email provider",
        credentialName: "IMAP sign-in credential",
        steps: [
            "Check your provider's IMAP setup instructions for the password "
                + "or credential they require.",
            "If normal password sign-in is blocked, look in account security settings for "
                + "\"app password\", \"app-specific password\", or \"secure mail key\".",
            "Paste the working password here. You may also need to set the IMAP server under Advanced."
        ],
        url: nil,
        passwordNoteOverride: "Unrecognized providers differ: some accept your normal email "
            + "password for IMAP, while others require an app-specific password "
            + "or similar credential."
    )

    /// "a" / "an" for the credential name, so the note reads naturally.
    private static func article(for noun: String) -> String {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        return vowels.contains(noun.lowercased().first ?? "x") ? "an" : "a"
    }
}
