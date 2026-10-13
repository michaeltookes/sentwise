import Foundation
import os
import SentwiseMail

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "GoogleSignIn")

/// "Sign in with Google" for Gmail and Google Workspace mailboxes (item 104).
///
/// The browser flow yields a token stored per account; the mailbox is then
/// verified and adopted through the exact same `testConnection(with:)` path as
/// an app password, carrying `GoogleMailCredential.marker` in the per-account
/// credential slot. App passwords stay the fallback and the only path for
/// non-Gmail providers. Offered on every plan tier.
extension AppState {

    /// The Google sign-in service plus the mail provider wrapped so Google
    /// mailboxes authenticate with XOAUTH2 (used once, by `AppState.init`).
    static func makeMailStack(
        base: MailProvider?,
        secrets: SecretStore
    ) -> (GoogleMailAuthService, MailProvider) {
        let auth = GoogleMailAuthService.live(secrets: secrets)
        return (auth, GoogleOAuthMailProvider(base: base ?? LiveMailProvider.imap(), auth: auth))
    }

    /// Whether this build can offer Google sign-in. Off when no client is
    /// bundled, and always off in Prowl hunt mode (no real browser/network).
    var isGoogleSignInAvailable: Bool {
        googleMailAuth.isAvailable && !ProwlHuntRuntime.current.isEnabled
    }

    /// Whether the focused, connected mailbox signed in with Google.
    var activeAccountUsesGoogleSignIn: Bool {
        isAccountConnected && GoogleMailCredential.isMarker(mailAppPassword)
    }

    /// Whether the saved mailbox `email` signed in with Google.
    func savedAccountUsesGoogleSignIn(_ email: String) -> Bool {
        let stored = (try? secrets.value(for: .mailAppPassword(email: email))) ?? nil
        return stored.map(GoogleMailCredential.isMarker) ?? false
    }

    /// The connect method to lead with for the address/host being entered.
    func recommendedConnectMethod(email: String, host: String) -> MailConnectMethod {
        MailConnectMethod.recommended(email: email, host: host, isGoogleSignInAvailable: isGoogleSignInAvailable)
    }

    /// Runs Google sign-in in the browser, then verifies and adopts the mailbox
    /// it authorized. Returns whether the mailbox is now connected.
    ///
    /// - Parameter loginHint: pre-selects an address on Google's chooser (the
    ///   email typed so far, or the saved account being reconnected).
    @discardableResult
    func connectWithGoogle(
        loginHint: String? = nil,
        messageSurface: TransientMessageSurface = .shared,
        shouldApplyResult: @escaping @MainActor (MailAccountCredentials) -> Bool = { _ in true }
    ) async -> Bool {
        setConnectionError(nil, for: messageSurface)
        clearWorkspaceAuthGuidance(for: messageSurface)
        guard isGoogleSignInAvailable else {
            setConnectionError(GmailAuthCoordinator.message(for: GmailAuthError.notConfigured), for: messageSurface)
            return false
        }
        guard !isConnecting else { return false }

        let authorization: GmailAuthorization
        do {
            authorization = try await googleMailAuth.signIn(loginHint: loginHint)
        } catch is CancellationError {
            return false
        } catch {
            setConnectionError(GmailAuthCoordinator.message(for: error), for: messageSurface)
            return false
        }

        let email = authorization.email
        let wasGoogleConnected = savedAccountUsesGoogleSignIn(email)
        let credentials = GoogleMailCredential.credentials(email: email)
        let connected = await testConnection(with: credentials, messageSurface: messageSurface, shouldApplyResult: shouldApplyResult)
        if !connected && !wasGoogleConnected {
            // Never leave an orphaned grant behind for a mailbox that didn't connect.
            await googleMailAuth.disconnect(email)
        }
        if connected {
            logger.info("Mailbox connected with Google sign-in")
        }
        return connected
    }

    /// Abandons a Google sign-in that is waiting on the browser.
    func cancelGoogleSignIn() {
        googleMailAuth.cancelSignIn()
    }

    /// Deletes `email`'s Google token and revokes the grant (best effort) once
    /// its credential slot no longer holds the Google marker — after a
    /// disconnect, a removal, or a switch of that mailbox to an app password.
    func forgetGoogleSignInIfReplaced(email: String, previousSecret: String?) {
        guard let previousSecret, GoogleMailCredential.isMarker(previousSecret) else { return }
        guard !savedAccountUsesGoogleSignIn(email) else { return }
        let auth = googleMailAuth
        Task { await auth.disconnect(email) }
    }
}
