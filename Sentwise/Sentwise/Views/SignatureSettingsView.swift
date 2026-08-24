import SwiftUI

/// The "Signature" section of the General settings tab (item 24): choose no
/// signature or a custom one, optionally seeded from the user's Sent mail.
///
/// A `Section` rather than a whole tab so it slots into `GeneralSettingsView`'s
/// form; kept in its own file so that view stays within the function-body limit.
struct SignatureSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Section("Signature") {
            Picker("Signature", selection: $appState.signaturePolicy) {
                Text("None").tag(SignaturePolicy.none)
                Text("Custom").tag(SignaturePolicy.custom)
            }
            .accessibilityIdentifier("signaturePolicyPicker")
            .accessibilityLabel("Email signature policy")

            if appState.signaturePolicy == .custom {
                TextEditor(text: $appState.signatureText)
                    .font(.body)
                    .frame(minHeight: 90)
                    .accessibilityIdentifier("signatureTextEditor")
                    .accessibilityLabel("Custom email signature")
                Text("Appended to drafts that don't already end with a signature. "
                     + "Quoted history stays below it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No signature is added to drafts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await appState.suggestSignatureFromSentMail() }
            } label: {
                if appState.isDetectingSignature {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Suggest from my Sent mail")
                }
            }
            .disabled(appState.isDetectingSignature || !appState.mailCredentials.isComplete)
            .accessibilityIdentifier("suggestSignatureButton")
            .accessibilityLabel("Suggest signature from my Sent mail")

            if let message = appState.signatureDetectionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(appState.signatureDetectionSucceeded == true ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("signatureDetectionMessage")
            }
        }
    }
}
