import Foundation
import SentwiseMail

/// A remembered email account the user can switch to without re-entering
/// credentials (item 48). Holds only the non-secret connection details —
/// email, IMAP host, and port. The app password is **never** stored here;
/// it lives in the macOS Keychain under a per-account key
/// (`SecretKey.mailAppPassword(email:)`), so removing an account can delete
/// exactly its secret and nothing leaks into the plaintext settings file.
struct SavedMailAccount: Codable, Equatable, Identifiable {
    /// The account's email address (as the user entered it, for display).
    var email: String
    /// The IMAP host this account connects through.
    var host: String
    /// The IMAP port this account connects through.
    var port: Int
    /// Outgoing (SMTP) host, when it differs from the provider default (item 31
    /// T31-6). `nil` for every pre-24 record: the transport falls back to the
    /// Google submission default, so existing accounts keep their behavior.
    var smtpHost: String?
    /// Outgoing (SMTP) port, or `nil` for the provider default.
    var smtpPort: Int?
    /// Outgoing transport security: `"tls"` (implicit TLS, port 465) or
    /// `"starttls"` (plain connect then STARTTLS, port 587). `nil` means `"tls"`.
    var smtpSecurity: String?
    /// How the account authenticates: `"google"`, `"microsoft"` or `"password"`
    /// (app password). `nil` only on records that predate schema 24 and could
    /// not be classified at migration time; the Keychain slot decides then.
    var authProvider: String?
    /// Special-folder names discovered from the server's `LIST` SPECIAL-USE
    /// attributes at verification (item 31, T31-8, additive: `nil` on older
    /// records and when discovery found nothing, which keeps the host defaults).
    var mailboxNaming: MailboxNaming?

    /// `smtpSecurity` raw values.
    static let smtpSecurityImplicitTLS = "tls"
    static let smtpSecuritySTARTTLS = "starttls"
    /// `authProvider` raw values.
    static let authProviderGoogle = "google"
    static let authProviderMicrosoft = "microsoft"
    static let authProviderPassword = "password"

    /// A stable identity derived from the normalized email, so the same mailbox
    /// under different casing/whitespace is treated as one account. This is also
    /// the discriminator used to derive the per-account Keychain key, so it must
    /// match `SecretKey.mailAppPassword(email:)`'s normalization.
    var id: String { Self.normalizedEmail(email) }

    init(
        email: String,
        host: String,
        port: Int,
        smtpHost: String? = nil,
        smtpPort: Int? = nil,
        smtpSecurity: String? = nil,
        authProvider: String? = nil,
        mailboxNaming: MailboxNaming? = nil
    ) {
        self.email = email
        self.host = host
        self.port = port
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
        self.authProvider = authProvider
        self.mailboxNaming = mailboxNaming
    }

    /// Lower-cased, whitespace-trimmed email — the canonical account identity.
    static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Transport round-trip (item 31, T31-6 / T31-8)

extension SavedMailAccount {
    /// Full credentials for this saved account: IMAP details plus the stored
    /// SMTP overrides and discovered folder names. A record without overrides
    /// (every pre-24 account) derives the historical defaults exactly as before.
    func credentials(appPassword: String) -> MailAccountCredentials {
        MailAccountCredentials(
            email: email,
            appPassword: appPassword,
            host: host,
            port: port,
            smtpHost: smtpHost,
            smtpPort: smtpPort ?? 465,
            smtpSecurity: smtpSecurity == Self.smtpSecuritySTARTTLS ? .startTLS : .implicitTLS,
            discoveredNaming: mailboxNaming
        )
    }

    /// `credentials` with this account's stored transport applied, but only while
    /// they still target the saved IMAP host (an edited host re-derives defaults).
    func applyingTransport(to credentials: MailAccountCredentials) -> MailAccountCredentials {
        guard credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(host) == .orderedSame else { return credentials }
        var result = credentials
        if let smtpHost { result.smtpHost = smtpHost }
        if let smtpPort { result.smtpPort = smtpPort }
        if smtpSecurity == Self.smtpSecuritySTARTTLS { result.smtpSecurity = .startTLS }
        if let mailboxNaming { result.discoveredNaming = mailboxNaming }
        return result
    }

    /// Records the non-default transport of verified `credentials`. Defaults leave
    /// the field `nil` (legacy shape); a changed IMAP host drops the old account's
    /// overrides first.
    mutating func recordTransport(from credentials: MailAccountCredentials, previousHost: String?) {
        let hostChanged = previousHost.map {
            $0.caseInsensitiveCompare(credentials.host) != .orderedSame
        } ?? false
        if hostChanged {
            smtpHost = nil
            smtpPort = nil
            smtpSecurity = nil
            mailboxNaming = nil
        }
        if credentials.smtpHost != MailAccountCredentials.derivedSMTPHost(from: credentials.host) {
            smtpHost = credentials.smtpHost
        }
        if credentials.smtpPort != 465 { smtpPort = credentials.smtpPort }
        if credentials.smtpSecurity == .startTLS { smtpSecurity = Self.smtpSecuritySTARTTLS }
        if let naming = credentials.discoveredNaming { mailboxNaming = naming }
    }
}
