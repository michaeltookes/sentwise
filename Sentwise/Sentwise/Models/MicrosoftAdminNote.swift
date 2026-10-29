import Foundation
import SentwiseMail

/// The plain-text note a user copies to the clipboard and sends to their IT
/// administrator when a Microsoft work account needs approval or has IMAP or
/// SMTP AUTH switched off (sign-in-first architecture 4.6). It carries the
/// user's own address and the Entra client id; never a token, code or tenant
/// secret.
enum MicrosoftAdminNote {
    enum Reason: Equatable {
        /// An administrator has to approve Sentwise for the organization.
        case consentRequired(tenantID: String?)
        /// IMAP or SMTP AUTH is switched off for this mailbox.
        case protocolDisabled(MailProtocol)
    }

    static let appName = "Sentwise"
    private static let tenantCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-."
    )
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    /// Permissions the app requests, as named in Entra.
    static let permissions = ["IMAP.AccessAsUser.All", "SMTP.Send", "offline_access", "openid", "profile", "email"]

    /// The tenant-scoped admin-consent URL, or nil when neither a usable
    /// tenant id nor an address domain is known (`common` cannot be used:
    /// consent is granted inside one tenant).
    static func adminConsentURL(clientID: String, tenantID: String?, address: String) -> URL? {
        guard let tenant = tenantSegment(tenantID: tenantID, address: address),
              let encodedClient = clientID.addingPercentEncoding(withAllowedCharacters: unreservedCharacters)
        else { return nil }
        return URL(string: "\(MicrosoftOAuth.authorityHost)/\(tenant)/adminconsent?client_id=\(encodedClient)")
    }

    static func text(reason: Reason, clientID: String, address: String) -> String {
        var lines = [
            "Hello,",
            "",
            "I would like to use \(appName), a Mac app, with my work mailbox (\(address)). "
                + "It needs your help before it can connect.",
            "",
            "Application: \(appName)",
            "Application (client) ID: \(clientID)",
            "Permissions requested (delegated): \(permissions.joined(separator: ", "))"
        ]
        switch reason {
        case .consentRequired(let tenantID):
            lines.append("")
            lines.append("Please review and approve \(appName) for the organization:")
            if let url = adminConsentURL(clientID: clientID, tenantID: tenantID, address: address) {
                lines.append(url.absoluteString)
            } else {
                lines.append("Grant admin consent for application ID \(clientID) in the Microsoft Entra admin center.")
            }
        case .protocolDisabled(.imap):
            lines.append("")
            lines.append("IMAP access is turned off for my mailbox. To turn it on (Exchange Online PowerShell):")
            lines.append("Set-CASMailbox -Identity \(address) -ImapEnabled $true")
        case .protocolDisabled(.smtp):
            lines.append("")
            lines.append("SMTP AUTH (sending) is turned off for my mailbox. To turn it on (Exchange Online PowerShell):")
            lines.append("Set-CASMailbox -Identity \(address) -SmtpClientAuthenticationDisabled $false")
        }
        lines.append("")
        lines.append("Thank you.")
        return lines.joined(separator: "\n")
    }

    /// A GUID tenant id, else the address's domain; anything with characters
    /// outside a tenant id or domain is rejected so it cannot alter the URL.
    private static func tenantSegment(tenantID: String?, address: String) -> String? {
        if let tenantID, isSafeTenant(tenantID) { return tenantID }
        guard let domain = address.split(separator: "@").last, address.contains("@"),
              isSafeTenant(String(domain)) else { return nil }
        return String(domain)
    }

    private static func isSafeTenant(_ value: String) -> Bool {
        !value.isEmpty && value.lowercased() != "common"
            && value.unicodeScalars.allSatisfy { tenantCharacters.contains($0) }
    }
}
