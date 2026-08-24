import SentwiseMail
import Foundation

/// Voice-profile learning on `AppState`. Kept in a separate file so `AppState`
/// stays within the file/type length limits.
extension AppState {

    /// How many recent Sent messages to sample when learning.
    static let voiceSampleLimit = 12

    /// Whether the prerequisites for learning are met (mail + AI connected).
    var canLearnVoice: Bool {
        isLLMConnected && mailCredentials.isComplete
    }

    /// Samples the Sent folder and derives a voice profile via the LLM.
    func learnVoiceProfile() async {
        voiceError = nil

        guard let llmConfiguration = currentVoiceLLMConfiguration else {
            voiceError = "Connect an AI provider first (Test Connection above)."
            return
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            voiceError = "Connect an email account first."
            return
        }

        isLearningVoice = true
        voiceProgress = "Finding your sent mail…"
        defer {
            isLearningVoice = false
            voiceProgress = nil
        }

        do {
            let bodies = try await fetchSentSampleBodies(credentials: credentials) { [weak self] progress in
                self?.voiceProgress = progress
            }
            guard isCurrentVoiceContext(credentials: credentials, llmConfiguration: llmConfiguration) else {
                voiceError = Self.staleVoiceLLMConfigurationMessage
                return
            }
            guard !bodies.isEmpty else {
                voiceError = "No sent messages found to learn from."
                return
            }
            voiceProgress = "Learning your voice from \(bodies.count) message\(bodies.count == 1 ? "" : "s")…"
            let profile = try await makeProfile(fromSentBodies: bodies, llmConfiguration: llmConfiguration)
            guard isCurrentVoiceContext(credentials: credentials, llmConfiguration: llmConfiguration) else {
                voiceError = Self.staleVoiceLLMConfigurationMessage
                return
            }
            persistence.saveVoiceProfile(profile)
            voiceProfile = profile
        } catch {
            let wasCurrent = isCurrentVoiceContext(credentials: credentials, llmConfiguration: llmConfiguration)
            let signedOut = await reconcileManagedAccountState(after: error, provider: llmConfiguration.provider)
            guard wasCurrent, signedOut || isCurrentVoiceContext(credentials: credentials, llmConfiguration: llmConfiguration) else {
                voiceError = Self.staleVoiceLLMConfigurationMessage
                return
            }
            voiceError = Self.voiceMessage(for: error)
        }
    }

    /// Clears the learned profile.
    func forgetVoiceProfile() {
        persistence.removeVoiceProfile()
        voiceProfile = nil
        voiceError = nil
    }

    // MARK: - Helpers

    /// Fetches recent Sent messages and reduces each to readable body text.
    /// Shared by voice-profile learning and signature detection (item 24). The
    /// optional `progress` closure reports per-message status; signature
    /// detection passes none since it runs without a progress display.
    func fetchSentSampleBodies(
        credentials: MailAccountCredentials,
        limit: Int = AppState.voiceSampleLimit,
        progress: ((String) -> Void)? = nil
    ) async throws -> [String] {
        let messages = try await mailProvider.fetchRecentMessages(
            credentials,
            mailbox: .sent,
            limit: limit
        )
        var bodies: [String] = []
        for (index, message) in messages.enumerated() {
            progress?("Reading message \(index + 1) of \(messages.count)…")
            let data = try await mailProvider.fetchBodyText(
                credentials,
                mailbox: .sent,
                uid: message.id,
                expectedUIDValidity: message.uidValidity
            )
            let text = MailBodyText.plainText(from: data)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bodies.append(text)
            }
        }
        return bodies
    }

    private var currentVoiceLLMConfiguration: VoiceLLMConfiguration? {
        guard isLLMConnected else { return nil }
        let key = Self.storedLLMAPIKey(
            provider: llmProviderKind,
            baseURL: currentLLMBaseURL,
            secrets: secrets
        )
        // Key-optional providers (local runtimes) learn with an empty key; cloud
        // providers still require a stored key.
        guard !key.isEmpty || !llmProviderKind.requiresAPIKey else { return nil }
        return VoiceLLMConfiguration(
            provider: llmProviderKind,
            model: resolvedLLMModel,
            apiKey: key,
            baseURL: currentLLMBaseURL
        )
    }

    private func isCurrentVoiceContext(
        credentials: MailAccountCredentials,
        llmConfiguration: VoiceLLMConfiguration
    ) -> Bool {
        mailCredentials == credentials && currentVoiceLLMConfiguration == llmConfiguration
    }

    private func makeProfile(
        fromSentBodies bodies: [String],
        llmConfiguration: VoiceLLMConfiguration
    ) async throws -> VoiceProfile {
        return try await VoiceProfiler().makeProfile(
            fromSentBodies: bodies,
            model: llmConfiguration.model,
            now: Date()
        ) { [llm] request in
            try await llm.complete(
                request,
                provider: llmConfiguration.provider,
                apiKey: llmConfiguration.apiKey,
                baseURL: llmConfiguration.baseURL
            )
        }
    }

    static func voiceMessage(for error: Error) -> String {
        switch error {
        case VoiceProfileError.noSamples:
            return "No sent messages found to learn from."
        case VoiceProfileError.invalidResponse(let detail):
            return "The model's reply couldn't be understood. (\(detail))"
        case is LLMError:
            return llmMessage(for: error)
        default:
            return message(for: error)
        }
    }

    private static let staleVoiceLLMConfigurationMessage = "Connection settings changed. Learn your voice again."
}

private struct VoiceLLMConfiguration: Equatable, Sendable {
    let provider: LLMProviderKind
    let model: String
    let apiKey: String
    let baseURL: String?
}
