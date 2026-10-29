import SentwiseMail
import SwiftUI

/// The connect-screen chooser (item 104): "Sign in with Google" leads for
/// Gmail and Google Workspace, and the app-password form stays available as
/// the documented fallback and the only path for other providers.
///
/// The app-password form is passed in and always rendered at the same spot
/// (inside a disclosure when Google leads, expanded automatically when the
/// typed address or host is not Google), so typing never loses focus when the
/// recommendation flips. Builds without a bundled client show just the form.
struct GoogleOrAppPasswordConnect<AppPasswordForm: View>: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var auth: GoogleMailAuthService
    let email: String
    let host: String
    var messageSurface: AppState.TransientMessageSurface = .shared
    var shouldApplyResult: @MainActor (MailAccountCredentials) -> Bool = { _ in true }
    var onConnected: () -> Void = {}
    @ViewBuilder let appPasswordForm: () -> AppPasswordForm

    @State private var showsAppPasswordForm = false

    private var layout: MailConnectLayout {
        appState.mailConnectLayout(email: email, host: host)
    }

    var body: some View {
        let layout = layout
        if layout.showsGoogle || layout.showsMicrosoft || layout.showsMicrosoftNotConfigured
            || appState.isGoogleSignInAvailable {
            if layout.showsGoogle {
                GoogleSignInButtonBlock(
                    auth: auth,
                    loginHint: email,
                    messageSurface: messageSurface,
                    shouldApplyResult: shouldApplyResult,
                    onConnected: onConnected
                )
            }
            if layout.showsMicrosoft || layout.showsMicrosoftNotConfigured {
                MicrosoftSignInButtonBlock(
                    auth: appState.microsoftMailAuth,
                    loginHint: email,
                    messageSurface: messageSurface,
                    shouldApplyResult: shouldApplyResult,
                    onConnected: onConnected
                )
            }
            let leads = layout.showsGoogle || layout.showsMicrosoft
            DisclosureGroup(
                leads ? "Use an app password instead" : "Connect with an app password",
                isExpanded: Binding(
                    get: { showsAppPasswordForm || layout.appPasswordExpanded },
                    set: { showsAppPasswordForm = $0 }
                )
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    appPasswordForm()
                }
            }
            .accessibilityIdentifier("appPasswordFallback")
        } else {
            appPasswordForm()
        }
    }
}

/// The "Sign in with Google" button with its browser-wait state.
struct GoogleSignInButtonBlock: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var auth: GoogleMailAuthService
    let loginHint: String
    var requireHintMatch = false
    let messageSurface: AppState.TransientMessageSurface
    let shouldApplyResult: @MainActor (MailAccountCredentials) -> Bool
    let onConnected: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    let hint = loginHint.trimmingCharacters(in: .whitespacesAndNewlines)
                    let connected = await appState.connectWithGoogle(
                        loginHint: hint.isEmpty ? nil : hint,
                        requireHintMatch: requireHintMatch,
                        messageSurface: messageSurface,
                        shouldApplyResult: shouldApplyResult
                    )
                    if connected { onConnected() }
                }
            } label: {
                Label(requireHintMatch ? "Sign in with Google again" : "Sign in with Google",
                      systemImage: "person.crop.circle.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isConnecting || auth.phase.isInProgress)
            .accessibilityIdentifier("signInWithGoogle")
            .accessibilityHint("Opens Google in your browser to connect Gmail without an app password")

            switch auth.phase {
            case .awaitingBrowser:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in with Google in your browser…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { appState.cancelGoogleSignIn() }
                        .controlSize(.small)
                        .accessibilityIdentifier("cancelGoogleSignIn")
                }
            case .exchangingCode:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting your mailbox…").font(.caption).foregroundStyle(.secondary)
                }
            case .idle, .failed:
                Text("Works with Gmail and Google Workspace — no app password needed. "
                     + "Sentwise reads your recent inbox on this Mac to find messages worth a reply, "
                     + "and sends mail to the drafting service only to write for you; "
                     + "nothing is stored on our servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Sign in with Google again" on a saved background mailbox whose grant
/// expired (`AppState.savedAccountNeedsGoogleReauth`). Signs in for exactly
/// that address; on success it becomes the focused mailbox and its paused
/// watcher resumes.
struct SavedGoogleMailboxReconnect: View {
    @EnvironmentObject var appState: AppState
    let email: String
    let shouldApplyResult: @MainActor (MailAccountCredentials) -> Bool

    var body: some View {
        GoogleSignInButtonBlock(
            auth: appState.googleMailAuth,
            loginHint: email,
            requireHintMatch: true,
            messageSurface: .settings,
            shouldApplyResult: shouldApplyResult,
            onConnected: {}
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sign in with Google again for \(email)")
    }
}

/// Copy for the Email Account settings confirmations, kept here so the
/// settings view stays within its length limits.
enum EmailAccountSettingsCopy {
    static func removeAccountMessage(_ email: String) -> String {
        "This forgets \(email) and deletes its saved password or Google sign-in from your Keychain. "
            + "Your mailbox on the server is never touched.\n\n"
            + "\"Remove & erase local data\" also deletes this Mac's cached mail for the "
            + "account — pending drafts, activity history, and the skipped-message log. "
            + "If it is the active account, the learned voice profile is cleared too. "
            + "\"Remove only\" keeps that local data."
    }

    static let disconnectMessage = "Erasing local data deletes this Mac's cached mail for this account — pending "
        + "drafts, activity history, learned voice profile, and the skipped-message log. "
        + "Your mailbox on the server is never touched. \"Disconnect only\" keeps that "
        + "local data so you can reconnect without re-learning your voice."
}
