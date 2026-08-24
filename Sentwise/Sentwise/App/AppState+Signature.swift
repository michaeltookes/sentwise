import SentwiseMail
import Foundation

/// Signature handling on `AppState` (item 24): the "Suggest from my Sent mail"
/// action and the draft-body finalizer that applies the configured signature
/// policy at assembly time. Kept in its own file so `AppState` stays within the
/// file/type length limits.
extension AppState {

    /// Applies the configured signature policy to a freshly generated draft body.
    /// Called at draft assembly for both workflows (inbox replies and post-call
    /// follow-ups) so a draft neither drops the expected signature nor duplicates
    /// one the model already wrote.
    func finalizedDraftBody(_ body: String) -> String {
        SignatureApplier.apply(policy: signaturePolicy, signature: signatureText, to: body)
    }

    /// Samples the user's recent Sent mail and, if a consistent signature is
    /// found, prefills the custom signature and switches the policy to custom.
    /// Always leaves clear, non-silent feedback (item 24 hard requirement).
    ///
    /// Uses no LLM — purely the `SignatureDetector` heuristics over the same Sent
    /// fetch that voice-profile learning uses — so it works even before an AI
    /// provider is connected.
    func suggestSignatureFromSentMail() async {
        guard !isDetectingSignature else { return }
        signatureDetectionMessage = nil
        signatureDetectionSucceeded = nil

        let credentials = mailCredentials
        guard credentials.isComplete else {
            reportSignatureDetection(succeeded: false, "Connect an email account first to detect your signature.")
            return
        }
        let startingSignaturePolicy = signaturePolicy
        let startingSignatureText = signatureText

        isDetectingSignature = true
        defer { isDetectingSignature = false }

        do {
            let bodies = try await fetchSentSampleBodies(credentials: credentials)
            guard mailCredentials == credentials else {
                reportSignatureDetection(
                    succeeded: false,
                    "Email account changed while detection was running. Try again."
                )
                return
            }
            guard !bodies.isEmpty else {
                reportSignatureDetection(
                    succeeded: false,
                    "No sent messages found to detect a signature from — enter one below."
                )
                return
            }
            if let detected = SignatureDetector.detect(fromSentBodies: bodies) {
                guard signaturePolicy == startingSignaturePolicy, signatureText == startingSignatureText else {
                    reportSignatureDetection(
                        succeeded: false,
                        "Signature settings changed while detection was running, so your edits were left unchanged."
                    )
                    return
                }
                (signatureText, signaturePolicy) = (detected, .custom)
                reportSignatureDetection(succeeded: true, "Found this in your recent Sent mail — edit if needed.")
            } else {
                reportSignatureDetection(
                    succeeded: false,
                    "Couldn't find a consistent signature in your Sent mail — enter one below."
                )
            }
        } catch {
            guard mailCredentials == credentials else {
                reportSignatureDetection(
                    succeeded: false,
                    "Email account changed while detection was running. Try again."
                )
                return
            }
            reportSignatureDetection(
                succeeded: false,
                "Couldn't read your Sent mail. \(AppState.message(for: error))"
            )
        }
    }

    private func reportSignatureDetection(succeeded: Bool, _ message: String) {
        signatureDetectionSucceeded = succeeded
        signatureDetectionMessage = message
    }

    func clearSignatureForAccountChange() {
        let hadSignature = signaturePolicy != .default
            || !signatureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        signaturePolicy = .default
        signatureText = ""
        if hadSignature {
            reportSignatureDetection(
                succeeded: false,
                "Signature cleared because the email account changed. Suggest or enter a signature for this account."
            )
        } else {
            signatureDetectionSucceeded = nil
            signatureDetectionMessage = nil
        }
    }
}
