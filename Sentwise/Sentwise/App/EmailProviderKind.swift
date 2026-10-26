import Foundation
import SentwiseMail

/// A recognized email provider, classified from an address's domain. Drives both
/// the IMAP-host suggestion (item 41) and the connect-screen credential guidance
/// (item 43), so the two share one source of truth for "which provider is this".
enum EmailProviderKind: Equatable, CaseIterable {
    case gmail
    case att
    case yahoo
    case aol
    case icloud

    /// Classifies an email address by domain, or `nil` when unrecognized.
    /// This also keeps host suggestion and credential guidance on one source of
    /// truth for provider variants.
    static func forEmail(_ email: String) -> EmailProviderKind? {
        guard let domain = Self.domain(of: email) else { return nil }
        switch domain {
        case "gmail.com", "googlemail.com":
            return .gmail
        case "att.net", "sbcglobal.net", "bellsouth.net":
            return .att
        case "yahoo.com", "ymail.com", "rocketmail.com":
            return .yahoo
        case "aol.com":
            return .aol
        case "icloud.com", "me.com", "mac.com":
            return .icloud
        default:
            return nil
        }
    }

    /// Classifies a configured IMAP host, or `nil` when it is not one of the
    /// provider defaults we know how to guide.
    static func forHost(_ host: String) -> EmailProviderKind? {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasDNSLabelSuffix(in: gmailHostSuffixes) {
            return .gmail
        }
        if normalized.hasDNSLabelSuffix(in: attHostSuffixes) {
            return .att
        }
        if normalized.hasDNSLabelSuffix(in: yahooHostSuffixes) {
            return .yahoo
        }
        if normalized.hasDNSLabelSuffix(in: aolHostSuffixes) {
            return .aol
        }
        if normalized.hasDNSLabelSuffix(in: icloudHostSuffixes) {
            return .icloud
        }
        return nil
    }

    /// The IMAP host for this provider (its SMTP host is derived from it).
    var imapHost: String {
        switch self {
        case .gmail: return "imap.gmail.com"
        case .att: return "imap.mail.att.net"
        case .yahoo: return "imap.mail.yahoo.com"
        case .aol: return "imap.aol.com"
        case .icloud: return "imap.mail.me.com"
        }
    }

    /// Every recognized provider host, treated as a "default" the domain-derived
    /// suggestion may replace (a hand-entered custom host is never one of these).
    static var allHosts: Set<String> {
        Set(allCases.map(\.imapHost))
    }

    /// The lowercased domain of an email address, or `nil` if malformed.
    static func domain(of email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = trimmed.lastIndex(of: "@") else { return nil }
        let domain = String(trimmed[trimmed.index(after: at)...])
        return domain.isEmpty ? nil : domain
    }

    /// A complete domain suitable for an MX query. Requiring at least two labels
    /// and a two-character TLD avoids DNS work for ordinary mid-typing states.
    static func validDomain(of email: String) -> String? {
        guard let domain = domain(of: email) else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty }),
              let topLevelDomain = labels.last,
              topLevelDomain.count >= 2 else { return nil }
        return domain
    }

    private static let gmailHostSuffixes = ["gmail.com", "googlemail.com"]
    private static let attHostSuffixes = ["att.net", "sbcglobal.net", "bellsouth.net"]
    private static let yahooHostSuffixes = ["yahoo.com", "ymail.com", "rocketmail.com"]
    private static let aolHostSuffixes = ["aol.com"]
    private static let icloudHostSuffixes = ["mail.me.com", "mail.icloud.com"]
}

enum MailCredentialPasswordNormalization {
    static func normalized(_ raw: String, email _: String, host: String) -> String {
        guard usesGroupedGeneratedCredential(host: host) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return MailAccountCredentials.normalizedGroupedAppPassword(raw)
    }

    private static func usesGroupedGeneratedCredential(host: String) -> Bool {
        EmailProviderKind.forHost(host) != nil
    }
}

private extension String {
    func hasDNSLabelSuffix(in suffixes: [String]) -> Bool {
        suffixes.contains { suffix in
            self == suffix || hasSuffix("." + suffix)
        }
    }
}
