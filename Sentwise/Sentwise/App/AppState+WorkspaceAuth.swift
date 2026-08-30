import SentwiseMail
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "WorkspaceAuth")

/// Google Workspace / Gmail policy-failure classification and the "Sign in with
/// Google" interest capture on `AppState` (item 75). When an IMAP connect fails
/// with an authentication error, this classifies the server text into a
/// `WorkspaceAuthFailure`, drives the targeted guidance block, and records a
/// PII-free activity entry so the maintainer can see how often launch users hit
/// each mode while dogfooding.
extension AppState {

    static let googleOAuthInterestTopic = "google-oauth"

    // MARK: - Classification

    /// Clears any prior Workspace guidance. Called when a fresh connect attempt
    /// starts, and on disconnect / add-account transitions, so stale guidance never
    /// lingers past the failure it described.
    func clearWorkspaceAuthGuidance() {
        workspaceAuthFailure = .none
        workspaceAuthIsCustomDomain = false
    }

    /// Classifies a failed connection's error against the credentials that were
    /// tried, updates the guidance state, and — when it's a recognized policy
    /// failure — records a metadata-only activity entry (class name only, never the
    /// email, server text, or credential).
    func classifyWorkspaceAuthFailure(_ error: Error, credentials: MailAccountCredentials) {
        guard case let MailError.authenticationFailed(serverText) = error else {
            clearWorkspaceAuthGuidance()
            return
        }

        let domain = EmailProviderKind.domain(of: credentials.email)
        let failure = WorkspaceAuthFailure.classify(
            serverText: serverText,
            emailDomain: domain,
            imapHost: credentials.host
        )
        workspaceAuthFailure = failure
        workspaceAuthIsCustomDomain = failure != .none
            && !WorkspaceAuthFailure.isConsumerGoogleDomain(domain)

        guard failure != .none else { return }
        recordWorkspaceAuthGuidanceActivity(failure)
    }

    /// The guidance copy for the current failure state, or `nil` when there is no
    /// recognized policy failure to guide.
    var workspaceAuthGuidance: WorkspaceAuthGuidance? {
        WorkspaceAuthGuidance.make(for: workspaceAuthFailure, isCustomDomain: workspaceAuthIsCustomDomain)
    }

    /// Records the failure class in activity history with no PII: no account,
    /// sender, subject, mailbox, or server text — only the class name in `detail`.
    private func recordWorkspaceAuthGuidanceActivity(_ failure: WorkspaceAuthFailure) {
        recordActivity(ActivityEvent(
            kind: .workspaceAuthGuidance,
            detail: failure.activityClassName
        ))
        logger.info("Recorded workspace auth guidance (\(failure.activityClassName, privacy: .public))")
    }

    // MARK: - "Sign in with Google" interest capture

    /// Whether the interest capture button should be offered: only when a managed
    /// account is signed in (mailbox connect can precede sign-in in edge flows, and
    /// the demand signal is per Sentwise account) and it hasn't been registered yet.
    var canOfferGoogleOAuthInterest: Bool {
        isManagedSignedIn && !googleOAuthInterestRegistered
    }

    /// Recomputes `googleOAuthInterestRegistered` for the current managed account.
    /// Called at launch and after sign-in so the button reflects this account's
    /// prior choice rather than another account's.
    func refreshGoogleOAuthInterestState() {
        guard isManagedSignedIn else {
            googleOAuthInterestRegistered = false
            return
        }
        googleOAuthInterestRegistered = googleOAuthInterestStore.isRegistered(
            accountKey: currentGoogleOAuthInterestAccountKey
        )
    }

    /// Registers interest in a revived "Sign in with Google" path (item 75). This
    /// is an explicit user action — consent — but nothing is ever sent without the
    /// click, matching the opt-in telemetry rule. In Prowl hunt mode it's a no-op
    /// stub: it never touches the network. On success the confirmation state is
    /// persisted locally so the button isn't re-offered.
    func registerGoogleOAuthInterest(isHuntMode: Bool = ProwlHuntRuntime.current.isEnabled) async {
        guard canOfferGoogleOAuthInterest else { return }
        if isHuntMode { return }

        googleOAuthInterestError = nil
        isRegisteringGoogleOAuthInterest = true
        defer { isRegisteringGoogleOAuthInterest = false }

        do {
            try await googleOAuthInterestClient.registerInterest(topic: Self.googleOAuthInterestTopic)
            markGoogleOAuthInterestRegisteredLocally()
        } catch {
            googleOAuthInterestError = Self.message(for: error)
            logger.error("Interest registration failed: \(error.localizedDescription)")
        }
    }

    private func markGoogleOAuthInterestRegisteredLocally() {
        googleOAuthInterestStore.markRegistered(accountKey: currentGoogleOAuthInterestAccountKey)
        googleOAuthInterestRegistered = true
    }

    private var currentGoogleOAuthInterestAccountKey: String {
        ManagedUsageAccountKey.make(from: managedAccountID)
    }
}
