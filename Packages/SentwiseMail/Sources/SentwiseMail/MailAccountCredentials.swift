import Foundation

/// Credentials for connecting to a mailbox over IMAP/SMTP.
///
/// Authenticates with `appPassword` by default. When `oauthAccessToken` is set
/// (the "Sign in with Google" path, item 104), sessions authenticate with SASL
/// `XOAUTH2` instead and `appPassword` is ignored.
///
/// Defaults target Gmail; `host`/`port` are overridable for other providers.
public struct MailAccountCredentials: Equatable, Sendable {
    public var email: String
    public var appPassword: String
    public var host: String
    public var port: Int
    /// The SMTP submission host used for sending. Defaults to the IMAP host with
    /// its `imap.` prefix swapped for `smtp.` (Gmail: `smtp.gmail.com`).
    public var smtpHost: String
    /// The SMTP submission port. Defaults to 465 (implicit TLS / SMTPS).
    public var smtpPort: Int
    /// A short-lived Google OAuth access token. When non-empty, IMAP and SMTP
    /// authenticate with `XOAUTH2` rather than the app password (item 104).
    public var oauthAccessToken: String?

    public init(
        email: String,
        appPassword: String,
        host: String = "imap.gmail.com",
        port: Int = 993,
        smtpHost: String? = nil,
        smtpPort: Int = 465,
        oauthAccessToken: String? = nil
    ) {
        self.email = email
        self.appPassword = appPassword
        self.host = host
        self.port = port
        self.smtpHost = smtpHost ?? Self.derivedSMTPHost(from: host)
        self.smtpPort = smtpPort
        self.oauthAccessToken = oauthAccessToken
    }

    /// How sessions with these credentials authenticate: `XOAUTH2` when an OAuth
    /// access token is present, otherwise the app password.
    public var authentication: MailAuthentication {
        if let token = oauthAccessToken, !token.isEmpty {
            return .xoauth2(accessToken: token)
        }
        return .password(appPassword)
    }

    /// Whether all required fields are present.
    public var isComplete: Bool {
        let hasSecret = !appPassword.isEmpty || !(oauthAccessToken ?? "").isEmpty
        return !email.isEmpty && hasSecret && !host.isEmpty && port > 0
    }

    /// The special-folder layout (Sent/Drafts/All-Mail/Junk) for this account's
    /// IMAP host, so operations target the right folder on non-Gmail providers.
    public var mailboxNaming: MailboxNaming { MailboxNaming.forHost(host) }

    /// Derives an SMTP submission host from an IMAP host by swapping a leading
    /// `imap.` for `smtp.`; other hosts are returned unchanged.
    static func derivedSMTPHost(from host: String) -> String {
        host.hasPrefix("imap.") ? "smtp." + host.dropFirst("imap.".count) : host
    }

    /// Strips grouping whitespace from providers whose generated app passwords
    /// are displayed as separated code blocks (e.g. `xxxx xxxx xxxx xxxx`).
    /// Use this only when the credential is known to be one of those generated
    /// passwords; ordinary IMAP passwords can legitimately contain spaces.
    public static func normalizedGroupedAppPassword(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines).joined()
    }
}
