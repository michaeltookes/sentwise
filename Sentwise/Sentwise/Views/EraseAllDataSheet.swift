import SwiftUI

/// Confirmation sheet for the irreversible "Erase all local data" action (item 96
/// / security finding A-L2). Removes everything under the app's Application Support
/// directory and every per-account Keychain secret, returning the running app to a
/// first-run state without a relaunch. Mirrors the managed-account
/// `DeleteAccountSheet` DELETE-gated pattern so the two destructive confirmations
/// feel identical.
struct EraseAllDataSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmText = ""
    @State private var errorMessage: String?

    private var canConfirm: Bool { confirmText == "DELETE" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Erase all local data?")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("This permanently removes everything Sentwise stores on this Mac:")
                    .font(.callout).bold()
                Text("• Your mailbox connection and all saved accounts\n"
                     + "• Pending drafts and activity history\n"
                     + "• Your learned voice profile and skipped-message log\n"
                     + "• All app settings and preferences\n"
                     + "• Every saved password and token in your Keychain")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Your mailbox on the server is never touched. Sentwise returns to its "
                 + "first-run state. This can't be undone. Type DELETE to confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("DELETE", text: $confirmText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("eraseAllDataConfirmField")
                .accessibilityLabel("Type DELETE to confirm")

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("eraseAllDataError")
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("eraseAllDataCancel")
                Spacer()
                Button(role: .destructive) {
                    performErase()
                } label: {
                    Text("Erase everything")
                }
                .disabled(!canConfirm)
                .accessibilityIdentifier("eraseAllDataConfirm")
                .accessibilityLabel("Confirm erase all local data")
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func performErase() {
        errorMessage = nil
        let keychainCleared = appState.eraseAllLocalData()
        if keychainCleared {
            dismiss()
        } else {
            // Files and in-memory state were still wiped; only the Keychain purge
            // failed, so surface that precisely rather than implying nothing happened.
            errorMessage = "Your local files were erased, but some Keychain items could not be "
                + "removed. Try again, or remove them from Keychain Access."
        }
    }
}
