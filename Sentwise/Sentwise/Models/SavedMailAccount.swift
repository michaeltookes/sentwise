import Foundation

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
        authProvider: String? = nil
    ) {
        self.email = email
        self.host = host
        self.port = port
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
        self.authProvider = authProvider
    }

    /// Lower-cased, whitespace-trimmed email — the canonical account identity.
    static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
