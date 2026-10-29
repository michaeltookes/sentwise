import Foundation
import os
import SentwiseMail

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "MicrosoftSignIn")

/// A Microsoft sign-in that stopped because an administrator must approve
/// Sentwise for the organization (item 31, T31-3/T31-5). Carries only what the
/// note for the administrator needs.
struct MicrosoftAdminApprovalRequest: Equatable {
    let tenantID: String?
    let address: String
}

extension GoogleMailAuthService {
    /// The Microsoft sign-in service: the same engine as Google's, driven by the
    /// bundled Microsoft client (nil, so "not configured", when the build has none).
    /// Tokens live under the `microsoft` Keychain prefix; Google's `gmail` prefix
    /// is untouched.
    static func liveMicrosoft(secrets: SecretStore) -> GoogleMailAuthService {
        let configuration = MicrosoftOAuthClientConfiguration.bundled()
        let store = GmailAuthStore(
            secrets: secrets,
            keychainPrefix: configuration?.keychainPrefix ?? OAuthProviderConfiguration.microsoftKeychainPrefix
        )
        let coordinator = configuration.map { client in
            GmailAuthCoordinator(
                client: client,
                store: store,
                tokenService: OAuthTokenService(transport: URLSessionTransport())
            )
        }
        return GoogleMailAuthService(
            coordinator: coordinator,
            tokenStore: store,
            credentialMarker: MicrosoftMailCredential.marker
        )
    }
}

/// "Sign in with Microsoft" for Outlook.com, Hotmail, Live and Microsoft 365
/// mailboxes (item 31, T31-5). Same adoption path as Google: the browser flow
/// yields a token, then the mailbox is verified through `testConnection`, which
/// for a Microsoft mailbox also probes SMTP AUTH (T31-7) before anything is adopted.
extension AppState {

    /// Whether this build can offer Microsoft sign-in. Off when no client id is
    /// bundled, and always off in Prowl hunt mode.
    var isMicrosoftSignInAvailable: Bool {
        microsoftMailAuth.isAvailable && !ProwlHuntRuntime.current.isEnabled
    }

    /// Whether the saved mailbox `email` signed in with Microsoft.
    func savedAccountUsesMicrosoftSignIn(_ email: String) -> Bool {
        let stored = (try? secrets.value(for: .mailAppPassword(email: email))) ?? nil
        return stored.map(MicrosoftMailCredential.isMarker) ?? false
    }

    /// The connect-chooser layout for what has been typed.
    func mailConnectLayout(email: String, host: String) -> MailConnectLayout {
        MailConnectLayout.make(
            email: email,
            host: host,
            isGoogleAvailable: isGoogleSignInAvailable,
            isMicrosoftConfigured: isMicrosoftSignInAvailable
        )
    }

    /// The state the Microsoft block shows right now.
    func microsoftSignInViewState(reauthenticateAddress: String? = nil) -> MicrosoftSignInViewState {
        if microsoftAdminApproval != nil, isMicrosoftSignInAvailable, !microsoftMailAuth.phase.isInProgress {
            return .consentRequired
        }
        return MicrosoftSignInViewState.make(
            isConfigured: isMicrosoftSignInAvailable,
            phase: microsoftMailAuth.phase,
            isVerifying: isConnecting,
            reauthenticateAddress: reauthenticateAddress,
            failure: nil
        )
    }

    /// The note an administrator can act on (copied by the user), or nil.
    func microsoftAdminNoteText() -> String? {
        guard let request = microsoftAdminApproval,
              let clientID = MicrosoftOAuthClientConfiguration.bundled()?.clientID else { return nil }
        return MicrosoftAdminNote.text(
            reason: .consentRequired(tenantID: request.tenantID),
            clientID: clientID,
            address: request.address
        )
    }

    /// Leaves the admin-approval screen so the user can pick another account.
    func chooseAnotherMicrosoftAccount() {
        microsoftAdminApproval = nil
        setConnectionError(nil, for: .shared)
    }

    func cancelMicrosoftSignIn() {
        microsoftMailAuth.cancelSignIn()
    }

    /// Runs Microsoft sign-in in the browser, then verifies (IMAP and SMTP AUTH)
    /// and adopts the mailbox it authorized. Returns whether it is now connected.
    @discardableResult
    func connectWithMicrosoft(
        loginHint: String? = nil,
        requireHintMatch: Bool = false,
        messageSurface: TransientMessageSurface = .shared,
        shouldApplyResult: @escaping @MainActor (MailAccountCredentials) -> Bool = { _ in true }
    ) async -> Bool {
        setConnectionError(nil, for: messageSurface)
        microsoftAdminApproval = nil
        guard isMicrosoftSignInAvailable else {
            setConnectionError(MicrosoftSignInCopy.notConfigured, for: messageSurface)
            return false
        }
        guard !microsoftMailAuth.isSignInPending else { return false }
        let attempt = beginMailConnectionAttempt()
        let localDataGeneration = localDataEraseGeneration
        let removalMark = microsoftMailAuth.accountRemovalMark()
        let settingsGeneration = settingsTransientMessageGeneration
        let isCurrentSurface: @MainActor () -> Bool = {
            self.isCurrentTransientMessageSurface(messageSurface, generation: settingsGeneration)
        }
        let isStale: @MainActor (String) -> Bool = { email in
            !self.isCurrentLocalDataGeneration(localDataGeneration)
                || self.microsoftMailAuth.wasAccountRemoved(email, since: removalMark)
        }

        let authorization: GmailAuthorization
        do {
            authorization = try await microsoftMailAuth.signIn(loginHint: loginHint, requireHintMatch: requireHintMatch)
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentLocalDataGeneration(localDataGeneration),
                  isCurrentMailConnectionAttempt(attempt), isCurrentSurface() else { return false }
            if case OAuthError.adminConsentRequired(let tenantID) = error {
                microsoftAdminApproval = MicrosoftAdminApprovalRequest(
                    tenantID: tenantID,
                    address: loginHint ?? ""
                )
            }
            setConnectionError(MicrosoftSignInCopy.message(for: error), for: messageSurface)
            return false
        }

        return await adoptMicrosoftAuthorization(
            authorization,
            attempt: attempt,
            isStale: isStale,
            messageSurface: messageSurface,
            shouldApplyResult: { isCurrentSurface() && shouldApplyResult($0) }
        )
    }

    /// Verifies and adopts the mailbox a finished browser flow authorized. The
    /// address and `tid` come from the ID token; a failed IMAP or SMTP AUTH check
    /// deletes the just-stored token and adopts nothing (T31-7).
    private func adoptMicrosoftAuthorization(
        _ authorization: GmailAuthorization,
        attempt: UInt64,
        isStale: @escaping @MainActor (String) -> Bool,
        messageSurface: TransientMessageSurface,
        shouldApplyResult: @escaping @MainActor (MailAccountCredentials) -> Bool
    ) async -> Bool {
        let email = authorization.email
        let dropThisGrant = { await self.microsoftMailAuth.discard(authorization) }
        guard !isStale(email) else {
            await dropThisGrant()
            return false
        }
        let wasMicrosoftConnected = savedAccountUsesMicrosoftSignIn(email)
        let credentials = MicrosoftMailCredential.credentials(email: email, tenantID: authorization.tenantID)
        guard isCurrentMailConnectionAttempt(attempt), shouldApplyResult(credentials) else {
            if !wasMicrosoftConnected { await dropThisGrant() }
            return false
        }
        let connected = await testConnection(
            with: credentials, messageSurface: messageSurface, attempt: attempt
        ) { !isStale(email) && shouldApplyResult($0) }
        guard !isStale(email) else {
            await dropThisGrant()
            return false
        }
        if !connected && !wasMicrosoftConnected {
            await dropThisGrant()
        }
        if connected { logger.info("Mailbox connected with Microsoft sign-in") }
        return connected
    }
}
