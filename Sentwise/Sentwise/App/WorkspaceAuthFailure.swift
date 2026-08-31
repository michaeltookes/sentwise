import Foundation

/// The Google-specific IMAP sign-in failures that deserve targeted, non-generic
/// guidance (item 75). The flagship ICP works on a company Google Workspace
/// account, and many Workspace admins turn off app passwords, disable IMAP, or
/// enforce a security-key/web-login policy — each of which makes the IMAP +
/// app-password path fail with a message the user reads as "Sentwise is broken".
///
/// This is a **pure classification** over the server text IMAP returned in
/// `MailError.authenticationFailed`, the address's domain, and the configured
/// IMAP host. It extends the item-43 `CredentialGuidance` pattern (provider-aware
/// connect-screen help) rather than forking it: `CredentialGuidance` explains how
/// to *get* the credential; `WorkspaceAuthFailure` explains why a correct-looking
/// credential is being *rejected by policy*.
enum WorkspaceAuthFailure: Equatable {
    /// The account rejected the app password on a custom-domain (Workspace) Google
    /// address. Google returns `[AUTHENTICATIONFAILED] Invalid credentials` both
    /// for a typo and for an admin who has disabled app passwords, so the guidance
    /// covers both. Consumer gmail.com/googlemail.com addresses are deliberately
    /// excluded — they get the existing typo/2-Step guidance instead.
    case appPasswordRejectedWorkspace
    /// IMAP access is turned off for the account (admin policy on Workspace, or the
    /// user's own Gmail setting on a consumer account).
    case imapDisabled
    /// Google blocked the sign-in and wants a web login first (new-device check or
    /// a security-key / advanced-protection policy).
    case webLoginRequired
    /// Not a recognized Workspace/Google policy failure — fall back to the generic
    /// connection error and the item-43 credential guidance.
    case none

    /// The stable, PII-free class name recorded in activity history (item 75) so
    /// the maintainer can see how often launch users hit each mode. Never carries
    /// the email, server text, or credential.
    var activityClassName: String {
        switch self {
        case .appPasswordRejectedWorkspace: return "appPasswordRejectedWorkspace"
        case .imapDisabled: return "imapDisabled"
        case .webLoginRequired: return "webLoginRequired"
        case .none: return "none"
        }
    }

    /// Classifies an IMAP authentication failure. Everything is matched
    /// case-insensitively against `serverText`.
    ///
    /// - Only **Google hosts** (detected from `imapHost`, e.g. `imap.gmail.com`)
    ///   are classified; any other host returns `.none`, because these are
    ///   Google-specific server messages and framings.
    /// - `[AUTHENTICATIONFAILED] Invalid credentials` is ambiguous (typo vs.
    ///   disabled app passwords), so it is only treated as
    ///   `.appPasswordRejectedWorkspace` for a **custom domain**; a consumer
    ///   gmail.com/googlemail.com address returns `.none` (existing guidance).
    /// - `IMAP access is disabled` / `[UNAVAILABLE]`-class IMAP text and the
    ///   web-login markers are unambiguous, so they classify on any Google host.
    static func classify(serverText: String, emailDomain: String?, imapHost: String) -> WorkspaceAuthFailure {
        guard isGoogleHost(imapHost) else { return .none }

        let text = serverText.lowercased()

        if text.contains("web login required")
            || text.contains("support.google.com/mail/accounts/answer/78754") {
            return .webLoginRequired
        }

        if text.contains("imap access is disabled")
            || (text.contains("[unavailable]") && text.contains("imap")) {
            return .imapDisabled
        }

        if text.contains("[authenticationfailed]") || text.contains("invalid credentials") {
            // Ambiguous: typo vs. admin-disabled app passwords. Only surface the
            // Workspace framing for a custom domain; consumer accounts fall back
            // to the item-43 typo/2-Step guidance.
            return isConsumerGoogleDomain(emailDomain) ? .none : .appPasswordRejectedWorkspace
        }

        return .none
    }

    /// Whether the configured IMAP host is one of Google's IMAP endpoints. Reuses
    /// the item-41/43 provider classifier so "which host is Google" has one source
    /// of truth.
    static func isGoogleHost(_ host: String) -> Bool {
        EmailProviderKind.forHost(host) == .gmail
    }

    /// Whether the address is a consumer Google domain (`gmail.com` /
    /// `googlemail.com`), which gets the existing typo/2-Step guidance rather than
    /// the "your admin may have disabled this" framing.
    static func isConsumerGoogleDomain(_ domain: String?) -> Bool {
        guard let domain = domain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !domain.isEmpty else {
            return false
        }
        return domain == "gmail.com" || domain == "googlemail.com"
    }
}

/// The connect-screen copy for a `WorkspaceAuthFailure` (item 75): what happened,
/// that it's a policy outside Sentwise's control, and concrete options. Mirrors
/// the `CredentialGuidance` shape (a value type with rendered strings) so the view
/// stays declarative and the copy is unit-testable.
struct WorkspaceAuthGuidance: Equatable {
    /// Plain-language headline of what Google reported.
    let headline: String
    /// One line making clear this is an account/admin policy, not a Sentwise bug.
    let explanation: String
    /// Concrete next steps, in order.
    let options: [String]
    /// Whether the "Ask your admin" copy button applies (only when an admin can
    /// actually change the policy — i.e. a custom Workspace domain).
    let showsAskAdmin: Bool
    /// A relevant Google support article, when one is stable.
    let supportURL: URL?

    /// The one-line, copyable message the user forwards to their Workspace admin.
    /// Fixed wording (item 75) that names both levers (app passwords and IMAP) and
    /// links Google's own article so the admin has the authoritative reference.
    static let askAdminMessage =
        "Could you enable app passwords (or IMAP access) for my account? "
        + "I'm using a local mail assistant that connects over IMAP — "
        + "Google support article: https://support.google.com/accounts/answer/185833"

    /// Builds the guidance for a failure class, tailoring admin-vs-personal copy
    /// from whether the address is a custom (Workspace) domain. Returns `nil` for
    /// `.none`, so a caller can render "no guidance block" uniformly.
    static func make(for failure: WorkspaceAuthFailure, isCustomDomain: Bool) -> WorkspaceAuthGuidance? {
        switch failure {
        case .none: return nil
        case .appPasswordRejectedWorkspace: return appPasswordRejected()
        case .imapDisabled: return imapDisabled(isCustomDomain: isCustomDomain)
        case .webLoginRequired: return webLoginRequired(isCustomDomain: isCustomDomain)
        }
    }

    /// A personal-account fallback offered by every class, so a blocked user is
    /// never stranded while an admin change is pending.
    private static let personalFallbackOption =
        "Meanwhile, connect a personal Google account (or another mailbox) so you can "
        + "keep using Sentwise."

    private static func appPasswordRejected() -> WorkspaceAuthGuidance {
        WorkspaceAuthGuidance(
            headline: "Your app password was rejected",
            explanation: "This can mean a typo — or, on a company Google Workspace account, "
                + "that your admin has turned off app passwords. That's an account policy, "
                + "not a problem with Sentwise.",
            options: [
                "Double-check the 16-character app password for typos, and that 2-Step "
                    + "Verification is still on for your account.",
                "Ask your Workspace admin to allow app passwords for your account — copy the "
                    + "message below to send them.",
                personalFallbackOption
            ],
            showsAskAdmin: true,
            supportURL: URL(string: "https://support.google.com/accounts/answer/185833")
        )
    }

    private static func imapDisabled(isCustomDomain: Bool) -> WorkspaceAuthGuidance {
        if isCustomDomain {
            return WorkspaceAuthGuidance(
                headline: "IMAP access is turned off",
                explanation: "Your Google Workspace admin has disabled IMAP for your account, "
                    + "so no IMAP mail app can connect. That's an admin policy, not a problem "
                    + "with Sentwise.",
                options: [
                    "Ask your Workspace admin to enable IMAP access for your account — copy "
                        + "the message below to send them.",
                    personalFallbackOption
                ],
                showsAskAdmin: true,
                supportURL: URL(string: "https://support.google.com/a/answer/105694")
            )
        }
        return WorkspaceAuthGuidance(
            headline: "IMAP access is turned off",
            explanation: "Personal Gmail keeps IMAP turned on now, so this usually means "
                + "Google rejected the current connection path or account security state, "
                + "not that there's a Gmail setting you can switch back on.",
            options: [
                "Sign in to this Google Account in your browser, confirm 2-Step Verification "
                    + "is still on, then create a fresh app password for Sentwise.",
                "Update the app password in Sentwise and run Test Connection again.",
                personalFallbackOption
            ],
            showsAskAdmin: false,
            supportURL: URL(string: "https://support.google.com/mail/answer/75726")
        )
    }

    private static func webLoginRequired(isCustomDomain: Bool) -> WorkspaceAuthGuidance {
        var options = [
            "Sign in to this account once at https://accounts.google.com in your browser, "
                + "then run Test Connection again."
        ]
        if isCustomDomain {
            options.append(
                "If it keeps failing on a Workspace account, ask your admin whether a "
                    + "security-key or advanced-protection policy is blocking app passwords — "
                    + "copy the message below to send them."
            )
        }
        options.append(personalFallbackOption)
        return WorkspaceAuthGuidance(
            headline: "Google needs you to sign in on the web first",
            explanation: "Google blocked this sign-in and wants you to confirm it in a "
                + "browser — usually a new-device check or a Workspace security policy. "
                + "That's Google's check, not a problem with Sentwise.",
            options: options,
            showsAskAdmin: isCustomDomain,
            supportURL: URL(string: "https://support.google.com/mail/accounts/answer/78754")
        )
    }
}
