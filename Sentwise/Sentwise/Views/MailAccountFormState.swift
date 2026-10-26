import SentwiseMail
import Foundation

/// Local credential-entry state for account forms that must not mutate AppState's
/// active mailbox until a connection has been verified.
struct MailAccountFormState: Equatable {
    var email = ""
    var appPassword = ""
    var host = ""
    var port = Settings.default.mailPort

    private var explicitHostEmail: String?
    private var hostEnteredBeforeEmail = false
    private var googleWorkspaceDomain: String?

    var credentials: MailAccountCredentials {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return MailAccountCredentials(
            email: trimmedEmail,
            appPassword: MailCredentialPasswordNormalization.normalized(
                appPassword,
                email: trimmedEmail,
                host: trimmedHost
            ),
            host: trimmedHost,
            port: port
        )
    }

    var credentialGuidanceHostFallback: String? {
        if hostWasExplicitlyEditedForCurrentAddress {
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedHost.isEmpty ? nil : trimmedHost
        }
        guard let googleWorkspaceDomain,
              googleWorkspaceDomain == EmailProviderKind.validDomain(of: email) else { return nil }
        return EmailProviderKind.gmail.imapHost
    }

    mutating func resetForNewAccount() {
        self = MailAccountFormState()
    }

    mutating func updateEmailFromUser(_ newEmail: String) {
        email = newEmail
        if googleWorkspaceDomain != EmailProviderKind.validDomain(of: newEmail) {
            googleWorkspaceDomain = nil
        }

        if hostEnteredBeforeEmail {
            guard Self.normalizedEmailDomainForHostTracking(newEmail) != nil else { return }
            setHostGuidanceTracking(
                email: Self.normalizedEmailForHostTracking(newEmail),
                pending: false
            )
            return
        }

        applySuggestedHostIfDefault()
    }

    mutating func commitEmailEditFromUser() {
        restorePendingHostGuidanceIfPossible()
        applySuggestedHostIfDefault()
    }

    static func detectedGoogleWorkspaceDomain(
        for email: String,
        using detector: GoogleWorkspaceMXDetector
    ) async -> String? {
        guard EmailProviderKind.forEmail(email) == nil,
              let domain = EmailProviderKind.validDomain(of: email),
              await detector.isGoogleHosted(domain: domain) else { return nil }
        return domain
    }

    mutating func applyGoogleWorkspaceSuggestion(for domain: String) {
        guard EmailProviderKind.validDomain(of: email) == domain else { return }
        googleWorkspaceDomain = domain
        let suggestion = EmailProviderKind.gmail.imapHost
        let currentHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isHostReplaceableBySuggestion(currentHost, suggestedHost: suggestion), currentHost != suggestion {
            host = suggestion
            markHostManagedByApp()
        }
    }

    mutating func updateHostFromUser(_ newHost: String) {
        host = newHost
        let trimmedHost = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = Self.normalizedEmailForHostTracking(email)
        let hasCompletedEmailDomain = Self.normalizedEmailDomainForHostTracking(email) != nil
        setHostGuidanceTracking(
            email: trimmedHost.isEmpty || !hasCompletedEmailDomain ? nil : normalizedEmail,
            pending: !trimmedHost.isEmpty && !hasCompletedEmailDomain
        )
    }

    private var hostWasExplicitlyEditedForCurrentAddress: Bool {
        guard let explicitHostEmail,
              let currentEmail = Self.normalizedEmailForHostTracking(email) else {
            return false
        }
        return explicitHostEmail == currentEmail
    }

    private mutating func restorePendingHostGuidanceIfPossible() {
        guard hostEnteredBeforeEmail,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.normalizedEmailDomainForHostTracking(email) != nil else {
            return
        }

        setHostGuidanceTracking(
            email: Self.normalizedEmailForHostTracking(email),
            pending: false
        )
    }

    private mutating func applySuggestedHostIfDefault() {
        let currentHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let domain = EmailProviderKind.validDomain(of: email)
        let workspaceSuggestion = googleWorkspaceDomain.flatMap {
            $0 == domain ? EmailProviderKind.gmail.imapHost : nil
        }

        guard let suggestion = EmailProviderKind.forEmail(email)?.imapHost ?? workspaceSuggestion else {
            if isHostReplaceableBySuggestion(currentHost, suggestedHost: nil), !currentHost.isEmpty {
                host = ""
                markHostManagedByApp()
            }
            return
        }

        if isHostReplaceableBySuggestion(currentHost, suggestedHost: suggestion), currentHost != suggestion {
            host = suggestion
            markHostManagedByApp()
        }
    }

    private func isHostReplaceableBySuggestion(
        _ currentHost: String,
        suggestedHost: String?
    ) -> Bool {
        if currentHost.isEmpty { return true }
        guard EmailProviderKind.allHosts.contains(currentHost) else { return false }
        if let suggestedHost, currentHost != suggestedHost { return true }
        return !hostWasExplicitlyEditedForCurrentAddress
    }

    private mutating func markHostManagedByApp() {
        setHostGuidanceTracking(email: nil, pending: false)
    }

    private mutating func setHostGuidanceTracking(email: String?, pending: Bool) {
        explicitHostEmail = email
        hostEnteredBeforeEmail = pending
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
}
