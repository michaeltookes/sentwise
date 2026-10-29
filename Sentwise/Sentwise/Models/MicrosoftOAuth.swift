import Foundation

/// Microsoft identity platform constants for "Sign in with Microsoft"
/// (sign-in-first architecture 4.2). Authority `common` serves personal
/// Microsoft accounts and work/school (Entra ID) accounts with one app
/// registration.
enum MicrosoftOAuth {
    static let authorityHost = "https://login.microsoftonline.com"
    static let authority = "common"
    static let authorizationEndpoint = URL(string: "\(authorityHost)/\(authority)/oauth2/v2.0/authorize")!
    static let tokenEndpoint = URL(string: "\(authorityHost)/\(authority)/oauth2/v2.0/token")!

    static let imapScope = "https://outlook.office.com/IMAP.AccessAsUser.All"
    static let smtpScope = "https://outlook.office.com/SMTP.Send"

    /// Resource-qualified scopes (the Outlook resource) plus the OpenID scopes
    /// that make the ID token carry the account identity and a refresh token.
    static let scopes = [imapScope, smtpScope, "offline_access", "openid", "profile", "email"]
    /// Without both mail scopes granted the mailbox cannot be read or sent from.
    static let requiredScopes = [imapScope, smtpScope]

    /// Tenant id of Microsoft's consumer (personal account) directory. A token
    /// issued by it means an Outlook.com/Hotmail/Live mailbox, which sends
    /// through `smtp-mail.outlook.com`; any other tenant is a work account.
    static let consumerTenantID = "9188040d-6c67-4c5b-b112-36a304b66dad"
    static let imapHost = "outlook.office365.com"
}

/// The non-secret marker stored in a Microsoft-signed-in mailbox's
/// per-account credential slot in place of an app password (mirrors
/// `GoogleMailCredential.marker`).
enum MicrosoftMailCredential {
    static let marker = "sentwise-microsoft-oauth:v1"
}

/// Reads this build's Microsoft client id from Info.plist, which the
/// `MicrosoftOAuth.xcconfig` build setting feeds. No real client id exists
/// until the Entra app is registered, so an empty value (the committed
/// default) means "not configured" and the feature stays off.
enum MicrosoftOAuthClientConfiguration {
    static let clientIDInfoKey = "SentwiseMicrosoftOAuthClientID"

    /// The bundled Microsoft configuration, or nil when this build has no client.
    static func bundled(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> OAuthProviderConfiguration? {
        guard let rawID = infoDictionary?[clientIDInfoKey] as? String else { return nil }
        let clientID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableClientID(clientID) else { return nil }
        return .microsoft(clientID: clientID)
    }

    /// An Entra application (client) ID is a GUID; empty values, unexpanded
    /// build variables and the committed placeholder are not usable.
    static func isUsableClientID(_ clientID: String) -> Bool {
        guard !GoogleOAuthClientConfiguration.isUnexpandedOrPlaceholder(clientID) else { return false }
        return UUID(uuidString: clientID) != nil
    }
}
