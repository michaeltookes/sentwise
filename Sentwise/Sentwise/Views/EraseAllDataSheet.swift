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
    @State private var isErasing = false

    private var canConfirm: Bool { confirmText == "DELETE" && !isErasing }

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
                    Task { await performErase() }
                } label: {
                    if isErasing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Erase everything")
                    }
                }
                .disabled(!canConfirm)
                .accessibilityIdentifier("eraseAllDataConfirm")
                .accessibilityLabel("Confirm erase all local data")
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(isErasing)
    }

    private func performErase() async {
        errorMessage = nil
        isErasing = true
        let result = await appState.eraseAllLocalData()
        isErasing = false
        if result.succeeded {
            dismiss()
        } else {
            errorMessage = Self.eraseErrorMessage(result)
        }
    }

    private static func eraseErrorMessage(_ result: LocalDataEraseResult) -> String {
        switch (result.persistenceError, result.keychainError) {
        case let (fileError?, keychainError?):
            return "Some local files and Keychain items could not be removed. "
                + "\(fileError) \(keychainError)"
        case let (fileError?, nil):
            return "Some local files could not be removed. \(fileError)"
        case let (nil, keychainError?):
            return "Your local files were erased, but some Keychain items could not be removed. "
                + "\(keychainError)"
        case (nil, nil):
            return ""
        }
    }
}
