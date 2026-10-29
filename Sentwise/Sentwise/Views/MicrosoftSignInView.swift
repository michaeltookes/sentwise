import AppKit
import SentwiseMail
import SwiftUI

/// "Continue with Microsoft" with its browser-wait, checking, consent-required
/// and reauthentication states (item 31, T31-5). The state itself comes from
/// `MicrosoftSignInViewState`, so every branch is unit-tested without the view.
struct MicrosoftSignInButtonBlock: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var auth: GoogleMailAuthService
    let loginHint: String
    var requireHintMatch = false
    let messageSurface: AppState.TransientMessageSurface
    let shouldApplyResult: @MainActor (MailAccountCredentials) -> Bool
    let onConnected: () -> Void

    @State private var noteCopied = false

    private var state: MicrosoftSignInViewState {
        appState.microsoftSignInViewState(reauthenticateAddress: requireHintMatch ? loginHint : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .notConfigured:
                Text(MicrosoftSignInCopy.notConfigured)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("microsoftNotConfigured")
            case .ready(let showsWorkNote):
                signInButton(title: MicrosoftSignInCopy.signInTitle)
                consentBlock(showsWorkNote: showsWorkNote)
            case .reauthenticate(let address):
                Text(MicrosoftSignInCopy.reauthenticate(address))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                signInButton(title: MicrosoftSignInCopy.reauthenticateTitle)
            case .waitingForBrowser:
                signInButton(title: MicrosoftSignInCopy.signInTitle)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(MicrosoftSignInCopy.waitingForBrowser).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { appState.cancelMicrosoftSignIn() }
                        .controlSize(.small)
                        .accessibilityIdentifier("cancelMicrosoftSignIn")
                        .accessibilityLabel("Cancel Microsoft sign-in")
                }
            case .checking:
                signInButton(title: MicrosoftSignInCopy.signInTitle)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(MicrosoftSignInCopy.checking).font(.caption).foregroundStyle(.secondary)
                }
            case .consentRequired:
                consentRequiredBlock(MicrosoftSignInCopy.adminApproval)
            case .protocolDisabled(let proto):
                consentRequiredBlock(MicrosoftSignInCopy.protocolDisabledMessage(proto))
            case .failed(let message):
                signInButton(title: MicrosoftSignInCopy.signInTitle)
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func signInButton(title: String) -> some View {
        Button {
            Task {
                let hint = loginHint.trimmingCharacters(in: .whitespacesAndNewlines)
                let connected = await appState.connectWithMicrosoft(
                    loginHint: hint.isEmpty ? nil : hint,
                    requireHintMatch: requireHintMatch,
                    messageSurface: messageSurface,
                    shouldApplyResult: shouldApplyResult
                )
                if connected { onConnected() }
            }
        } label: {
            Label(title, systemImage: "person.crop.circle.badge.checkmark")
        }
        .buttonStyle(.borderedProminent)
        .disabled(appState.isConnecting || auth.phase.isInProgress)
        .accessibilityIdentifier("signInWithMicrosoft")
        .accessibilityLabel(title)
        .accessibilityHint(MicrosoftSignInCopy.signInHint)
    }

    private func consentBlock(showsWorkNote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MicrosoftSignInCopy.consentHeading).font(.caption.weight(.semibold))
            Text(MicrosoftSignInCopy.consentSummary)
            if showsWorkNote { Text(MicrosoftSignInCopy.workAccountNote) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func consentRequiredBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(MicrosoftSignInCopy.copyAdminNote) {
                    if let note = appState.microsoftAdminNoteText() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note, forType: .string)
                        noteCopied = true
                    }
                }
                .accessibilityIdentifier("copyMicrosoftAdminNote")
                .accessibilityHint("Copies a note you can send to your IT administrator")
                Button(MicrosoftSignInCopy.chooseAnotherAccount) {
                    noteCopied = false
                    appState.chooseAnotherMicrosoftAccount()
                }
                .accessibilityIdentifier("chooseAnotherMicrosoftAccount")
            }
            if noteCopied {
                Text(MicrosoftSignInCopy.adminNoteCopied).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// "Sign in with Microsoft Again" on a saved background mailbox whose grant
/// needs reauthentication; signs in for exactly that address.
struct SavedMicrosoftMailboxReconnect: View {
    @EnvironmentObject var appState: AppState
    let email: String
    let shouldApplyResult: @MainActor (MailAccountCredentials) -> Bool

    var body: some View {
        MicrosoftSignInButtonBlock(
            auth: appState.microsoftMailAuth,
            loginHint: email,
            requireHintMatch: true,
            messageSurface: .settings,
            shouldApplyResult: shouldApplyResult,
            onConnected: {}
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sign in with Microsoft again for \(email)")
    }
}

/// "Sign in again" for the focused mailbox in Email Account settings: the
/// Google or Microsoft block, whichever the connected mailbox signed in with.
struct ActiveMailboxReauth: View {
    @EnvironmentObject var appState: AppState
    let sessionID: UUID
    let accepts: (UUID) -> Bool

    var body: some View {
        let email = appState.mailEmail
        if appState.activeAccountUsesGoogleSignIn && appState.isGoogleSignInAvailable {
            GoogleSignInButtonBlock(
                auth: appState.googleMailAuth,
                loginHint: email,
                requireHintMatch: true,
                messageSurface: .settings,
                shouldApplyResult: { _ in
                    self.appState.activeAccountUsesGoogleSignIn && self.appState.mailEmail == email
                        && self.accepts(sessionID)
                },
                onConnected: {}
            )
        }
        if appState.activeAccountUsesMicrosoftSignIn && appState.isMicrosoftSignInAvailable {
            MicrosoftSignInButtonBlock(
                auth: appState.microsoftMailAuth,
                loginHint: email,
                requireHintMatch: true,
                messageSurface: .settings,
                shouldApplyResult: { _ in
                    self.appState.activeAccountUsesMicrosoftSignIn && self.appState.mailEmail == email
                        && self.accepts(sessionID)
                },
                onConnected: {}
            )
        }
    }
}
