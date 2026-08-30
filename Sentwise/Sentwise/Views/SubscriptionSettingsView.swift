import SwiftUI

/// The "Subscription" tab of Settings (backlog item 73): the Sentwise account
/// home. Shows the signed-in account email, plan / trial / renewal, weekly usage
/// (reused from `ManagedUsageView`), a manage-billing entry point (a stub until
/// checkout ships in 56c), sign-out, and a guarded delete-account flow. When
/// signed out it reuses the same managed sign-in controls as the AI tab.
///
/// This is distinct from the "Account" tab, which is the *mailbox* (IMAP)
/// account. This pane is the *Sentwise* account behind managed inference.
struct SubscriptionSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showDeleteSheet = false

    /// Presentation for the plan/trial/renewal rows, recomputed from the latest
    /// status each render (its day math reads "now" at render time).
    private var model: SubscriptionPaneModel {
        SubscriptionPaneModel.make(from: appState.managedAccountStatus)
    }

    /// The billing-portal URL when the Worker provides one (nil until 56c).
    private var manageBillingURL: URL? {
        guard let raw = appState.managedAccountStatus?.subscription?.manageBillingURL,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var body: some View {
        Form {
            if appState.isManagedSignedIn {
                signedInContent
            } else {
                signedOutContent
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("subscriptionTab")
        .sheet(isPresented: $showDeleteSheet) {
            DeleteAccountSheet()
                .environmentObject(appState)
        }
        // Single status refresh on tab open — lives on the outer container (not
        // inside an `if let`) so it runs even while the status is still unknown
        // (item 73, mirroring the 56b review note). Populates email/plan/quota in
        // one `/v1/me` call.
        .task { await appState.refreshManagedQuota() }
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signedOutContent: some View {
        Section("Sentwise account") {
            if appState.didDeleteManagedAccount {
                Label("Your Sentwise account was deleted.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("accountDeletedConfirmation")
            }
            Text("Sign in to see your plan, trial, and usage — and to draft with Sentwise AI. "
                 + "14-day free trial, no API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ManagedSignInControls()
            ManagedAccountErrorMessage()
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private var signedInContent: some View {
        Section("Account") {
            LabeledContent("Email") {
                Text(appState.managedAccountEmail)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("subscriptionAccountEmail")
            }
            LabeledContent("Plan") {
                Text(model.planText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("subscriptionPlan")
            }
            if let secondary = model.secondaryText {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(model.isProblemState ? .red : .secondary)
                    .accessibilityIdentifier("subscriptionPlanDetail")
            }
            if model.showsOwnKeyFallback {
                Button("Use your own AI key instead") {
                    appState.openSettingsHandler?(.ai)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("subscriptionOwnKeyFallback")
                .accessibilityLabel("Switch to using your own AI key")
            }
        }

        Section("Usage") {
            ManagedUsageView()
        }

        Section("Billing") {
            Button("Manage billing") {
                if let url = manageBillingURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(manageBillingURL == nil)
            .accessibilityIdentifier("manageBilling")
            .accessibilityLabel("Manage billing")

            if manageBillingURL == nil {
                Text("Billing management arrives with checkout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("manageBillingUnavailable")
            }
        }

        Section {
            Button("Sign out", role: .destructive) {
                Task { await appState.signOutManaged() }
            }
            .disabled(appState.isManagedBusy)
            .accessibilityIdentifier("subscriptionSignOut")
            .accessibilityLabel("Sign out of Sentwise AI")
        }

        Section {
            Button("Delete account", role: .destructive) {
                showDeleteSheet = true
            }
            .disabled(appState.isManagedBusy)
            .accessibilityIdentifier("deleteAccount")
            .accessibilityLabel("Delete Sentwise account")

            Text("Removes your Sentwise account and its server-side usage counters. "
                 + "Your mail, learned voice profile, drafts, and settings on this Mac are untouched.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        ManagedAccountErrorMessage()
    }
}

/// Confirmation sheet for irreversible account deletion (item 73). States exactly
/// what is removed (Sentwise account + server-side usage counters) and what is
/// not (mail, voice profile, drafts, and settings on this Mac), and gates the
/// destructive action behind typing `DELETE`.
struct DeleteAccountSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmText = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var canConfirm: Bool { confirmText == "DELETE" && !isDeleting }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete your Sentwise account?")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("This permanently removes:").font(.callout).bold()
                Text("• Your Sentwise account\n• Your server-side usage counters")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("This does NOT touch anything on this Mac:").font(.callout).bold()
                Text("• Your mail\n• Your learned voice profile\n• Your drafts\n• Your settings")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("This can't be undone. Type DELETE to confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("DELETE", text: $confirmText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("deleteAccountConfirmField")
                .accessibilityLabel("Type DELETE to confirm")

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("deleteAccountError")
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("deleteAccountCancel")
                Spacer()
                Button(role: .destructive) {
                    Task { await performDelete() }
                } label: {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Delete account")
                    }
                }
                .disabled(!canConfirm)
                .accessibilityIdentifier("deleteAccountConfirm")
                .accessibilityLabel("Confirm delete account")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func performDelete() async {
        errorMessage = nil
        isDeleting = true
        let succeeded = await appState.deleteManagedAccount()
        isDeleting = false
        if succeeded {
            dismiss()
        } else {
            // Keep the sheet open and surface the mapped failure message.
            errorMessage = appState.managedError ?? "We couldn't delete your account. Please try again."
        }
    }
}
