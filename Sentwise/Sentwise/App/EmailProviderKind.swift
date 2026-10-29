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
    case microsoft

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
            return Self.microsoftConsumerDomains.contains(domain) ? .microsoft : nil
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
        if normalized.hasDNSLabelSuffix(in: microsoftHostSuffixes) {
            return .microsoft
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
        case .microsoft: return MicrosoftOAuth.imapHost
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
    private static let microsoftHostSuffixes = ["office365.com", "outlook.office.com", "outlook.com"]

    /// Consumer Microsoft mailboxes: the global domains plus the regional
    /// outlook/hotmail/live families. Work and school (Microsoft 365) domains
    /// are custom, so they are found by MX (`Microsoft365MXDetector`), not here.
    static let microsoftConsumerDomains: Set<String> = {
        let outlook = ["com", "at", "be", "cl", "cz", "de", "dk", "es", "fr", "hu", "ie", "in", "it", "jp",
                       "kr", "lv", "my", "ph", "pt", "sa", "sg", "sk", "th", "co.id", "co.il", "co.nz",
                       "co.th", "com.ar", "com.au", "com.br", "com.gr", "com.tr", "com.vn"]
        let hotmail = ["com", "co.uk", "fr", "de", "it", "es", "be", "nl", "se", "dk", "no", "fi", "at", "ch",
                       "gr", "ca", "cl", "cz", "hu", "lv", "my", "ph", "pt", "sg", "sk", "sa", "co.id",
                       "co.il", "co.jp", "co.nz", "co.th", "com.ar", "com.au", "com.br", "com.tr", "com.vn"]
        let live = ["com", "co.uk", "fr", "de", "it", "nl", "se", "dk", "no", "at", "be", "ie", "ca", "cl",
                    "cn", "hk", "in", "jp", "ru", "co.za", "co.jp", "co.kr", "com.ar", "com.au", "com.mx",
                    "com.pt", "com.ph"]
        var domains: Set<String> = ["msn.com", "windowslive.com", "passport.com"]
        domains.formUnion(outlook.map { "outlook." + $0 })
        domains.formUnion(hotmail.map { "hotmail." + $0 })
        domains.formUnion(live.map { "live." + $0 })
        return domains
    }()
}

enum MailCredentialPasswordNormalization {
    static func normalized(_ raw: String, email _: String, host: String) -> String {
        guard usesGroupedGeneratedCredential(host: host) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return MailAccountCredentials.normalizedGroupedAppPassword(raw)
    }

    private static func usesGroupedGeneratedCredential(host: String) -> Bool {
        // Microsoft app passwords are not grouped 16-character codes, so the
        // grouped-code normalization (which strips spaces) must not apply.
        guard let kind = EmailProviderKind.forHost(host) else { return false }
        return kind != .microsoft
    }
}

private extension String {
    func hasDNSLabelSuffix(in suffixes: [String]) -> Bool {
        suffixes.contains { suffix in
            self == suffix || hasSuffix("." + suffix)
        }
    }
}
