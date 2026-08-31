import SentwiseMail
import Foundation

/// Provider-awareness helpers on `AppState`: special-folder capability for the
/// connected account and IMAP-host suggestions from an email domain, so
/// non-Gmail users (Yahoo/AT&T) don't hit Gmail-only assumptions.
extension AppState {

    /// Host fallback for provider guidance. Only hosts the user typed in
    /// Advanced count; loaded defaults and auto-suggestions can be stale.
    var credentialGuidanceHostFallback: String? {
        guard mailHostWasExplicitlyEditedForCurrentAddress else { return nil }
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? nil : host
    }

    var mailHostWasExplicitlyEditedForCurrentAddress: Bool {
        guard let editedEmail = mailHostExplicitlyEditedEmail,
              let currentEmail = Self.normalizedEmailForHostTracking(mailEmail) else {
            return false
        }
        return editedEmail == currentEmail
    }

    /// Routes email-field edits through host tracking before applying provider
    /// suggestions. An explicit host stays attached while the same custom
    /// domain address is being edited, but recognized or unrelated domains can
    /// supersede a provider host from the previous address.
    func updateMailEmailFromUser(_ email: String) {
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trackedDomain = mailHostExplicitlyEditedEmail.flatMap(Self.normalizedEmailDomainForHostTracking)
        let hasHostAssociatedWithTrackedEmail = trackedDomain != nil && !host.isEmpty
        let hasHostEnteredBeforeEmail = mailHostExplicitlyEditedBeforeEmail && !host.isEmpty

        let changed = mailEmail != email
        mailEmail = email
        if changed {
            clearWorkspaceAuthGuidance()
        }

        if hasHostEnteredBeforeEmail {
            guard let currentDomain = Self.normalizedEmailDomainForHostTracking(email) else {
                return
            }

            if let trackedDomain {
                if trackedDomain == currentDomain {
                    setMailHostGuidanceTracking(
                        email: Self.normalizedEmailForHostTracking(email),
                        pending: false
                    )
                    return
                }

                // A valid-looking domain can still be a mid-edit prefix; resolve
                // mismatches only when the user submits or tests the connection.
                return
            } else {
                // Without a prior domain, wait for submit/test before binding the
                // host to a valid-looking address that may still be mid-typing.
                return
            }
        } else if hasHostAssociatedWithTrackedEmail {
            guard let currentDomain = Self.normalizedEmailDomainForHostTracking(email) else {
                setMailHostGuidanceTracking(email: mailHostExplicitlyEditedEmail, pending: true)
                return
            }

            if trackedDomain == currentDomain {
                setMailHostGuidanceTracking(
                    email: Self.normalizedEmailForHostTracking(email),
                    pending: false
                )
                return
            }

            mailHost = ""
            markMailHostManagedByApp()
        }

        applySuggestedHostIfDefault()
    }

    /// Resolves an in-progress email edit before using the current inputs for a
    /// connection attempt or explicit field submission.
    func commitMailEmailEditFromUser() {
        restorePendingMailHostGuidanceIfPossible(clearMismatchedDomain: true)
        guard !mailHostExplicitlyEditedBeforeEmail else { return }
        applySuggestedHostIfDefault()
    }

    /// Routes Advanced host-field edits through explicit tracking, so a
    /// provider host typed for a custom domain is not treated as a stale default.
    func updateMailHostFromUser(_ host: String) {
        let changed = mailHost != host
        mailHost = host
        if changed {
            clearWorkspaceAuthGuidance()
        }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = Self.normalizedEmailForHostTracking(mailEmail)
        let hasCompletedEmailDomain = Self.normalizedEmailDomainForHostTracking(mailEmail) != nil
        setMailHostGuidanceTracking(
            email: normalizedHost.isEmpty || !hasCompletedEmailDomain ? nil : normalizedEmail,
            pending: !normalizedHost.isEmpty && !hasCompletedEmailDomain
        )
    }

    func updateMailAppPasswordFromUser(_ appPassword: String) {
        guard mailAppPassword != appPassword else { return }
        mailAppPassword = appPassword
        clearWorkspaceAuthGuidance()
    }

    func updateMailPortFromUser(_ port: Int) {
        guard mailPort != port else { return }
        mailPort = port
        clearWorkspaceAuthGuidance()
    }

    private func isMailHostReplaceableBySuggestion(
        _ normalizedHost: String,
        suggestedHost: String?
    ) -> Bool {
        if normalizedHost.isEmpty { return true }
        guard EmailProviderKind.allHosts.contains(normalizedHost) else { return false }
        if let suggestedHost, normalizedHost != suggestedHost { return true }
        return !mailHostWasExplicitlyEditedForCurrentAddress
    }

    private func markMailHostManagedByApp() {
        setMailHostGuidanceTracking(email: nil, pending: false)
    }

    private func setMailHostGuidanceTracking(email: String?, pending: Bool) {
        guard mailHostExplicitlyEditedEmail != email
            || mailHostExplicitlyEditedBeforeEmail != pending else {
            return
        }

        objectWillChange.send()
        mailHostExplicitlyEditedEmail = email
        mailHostExplicitlyEditedBeforeEmail = pending
    }

    func restoreMailHostGuidanceFromSettings(_ settings: Settings) {
        if !mailHostWasExplicitlyEditedForCurrentAddress,
           !mailHostExplicitlyEditedBeforeEmail {
            setMailHostGuidanceTracking(email: nil, pending: false)
        }

        restorePendingMailHostGuidanceIfPossible()

        if shouldMigrateLegacyMailHostGuidance(from: settings) {
            setMailHostGuidanceTracking(email: Self.normalizedEmailForHostTracking(mailEmail), pending: false)
        }

        if isAccountConnected {
            markMailHostVerifiedForGuidance()
        } else if Self.normalizedEmailForHostTracking(mailEmail) != nil,
                  !mailHostExplicitlyEditedBeforeEmail {
            applySuggestedHostIfDefault()
        }
    }

    func markMailHostVerifiedForGuidance() {
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let guidanceEmail = Self.normalizedEmailForHostTracking(mailEmail),
              !host.isEmpty else {
            setMailHostGuidanceTracking(email: nil, pending: false)
            return
        }

        if let suggestedHost = Self.suggestedIMAPHost(forEmail: mailEmail),
           host == suggestedHost {
            setMailHostGuidanceTracking(email: nil, pending: false)
            return
        }

        setMailHostGuidanceTracking(email: guidanceEmail, pending: false)
    }

    private func restorePendingMailHostGuidanceIfPossible(clearMismatchedDomain: Bool = false) {
        guard mailHostExplicitlyEditedBeforeEmail else { return }

        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            setMailHostGuidanceTracking(email: nil, pending: false)
            return
        }

        guard let currentDomain = Self.normalizedEmailDomainForHostTracking(mailEmail) else {
            return
        }

        if let trackedDomain = mailHostExplicitlyEditedEmail.flatMap(Self.normalizedEmailDomainForHostTracking),
           trackedDomain != currentDomain {
            guard clearMismatchedDomain else { return }
            mailHost = ""
            markMailHostManagedByApp()
        } else {
            setMailHostGuidanceTracking(
                email: Self.normalizedEmailForHostTracking(mailEmail),
                pending: false
            )
        }
    }

    private func shouldMigrateLegacyMailHostGuidance(from settings: Settings) -> Bool {
        let host = mailHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard settings.schemaVersion < Settings.mailHostGuidanceSchemaVersion,
              settings.mailHostGuidanceEmail == nil,
              Self.normalizedEmailDomainForHostTracking(mailEmail) != nil,
              !host.isEmpty else {
            return false
        }

        if let suggestedHost = Self.suggestedIMAPHost(forEmail: mailEmail) {
            return host != suggestedHost
                && (!EmailProviderKind.allHosts.contains(host) || settings.onboardingCompleted)
        }

        return host != Settings.default.mailHost || settings.onboardingCompleted
    }

    private static func normalizedEmailForHostTracking(_ email: String) -> String? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedEmailDomainForHostTracking(_ email: String) -> String? {
        guard let normalizedEmail = normalizedEmailForHostTracking(email),
              let separator = normalizedEmail.lastIndex(of: "@") else {
            return nil
        }
        let domain = normalizedEmail[normalizedEmail.index(after: separator)...]
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty }),
              let topLevelDomain = labels.last,
              topLevelDomain.count >= 2 else {
            return nil
        }
        return String(domain)
    }

    /// The special-folder layout for the currently-entered IMAP host.
    var connectedMailboxNaming: MailboxNaming { MailboxNaming.forHost(mailHost) }

    /// Whether the connected provider exposes an all-mail folder. Drives whether
    /// the browser offers an "All Mail" target (Yahoo/AT&T have none).
    var supportsAllMailFolder: Bool { connectedMailboxNaming.supportsAllMail }

    /// Suggests an IMAP host from an email address's domain, so users don't have
    /// to know their provider's server name. Returns nil for unrecognized or
    /// malformed domains. Limited to providers that work over our IMAP +
    /// app-password path with a correctly-derived SMTP host.
    static func suggestedIMAPHost(forEmail email: String) -> String? {
        EmailProviderKind.forEmail(email)?.imapHost
    }

    /// Auto-fills the IMAP host from the email domain when the user hasn't set a
    /// custom one — i.e. the host is empty or still an app-managed provider
    /// default. If the domain is unrecognized, stale provider defaults are
    /// cleared so credential guidance does not infer Gmail/AT&T/etc. from an
    /// untouched or previous-account host. A host typed in Advanced is preserved
    /// for custom domains, but a recognized address can replace a mismatched
    /// provider host from the previous address.
    func applySuggestedHostIfDefault() {
        let current = mailHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let suggestion = Self.suggestedIMAPHost(forEmail: mailEmail) else {
            if isMailHostReplaceableBySuggestion(current, suggestedHost: nil), !current.isEmpty {
                mailHost = ""
                markMailHostManagedByApp()
            }
            return
        }

        if isMailHostReplaceableBySuggestion(current, suggestedHost: suggestion), current != suggestion {
            mailHost = suggestion
            markMailHostManagedByApp()
        }
    }
}
