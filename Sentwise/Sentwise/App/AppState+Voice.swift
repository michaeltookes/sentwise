import SentwiseMail
import Foundation

/// Voice-profile learning on `AppState`. Kept in a separate file so `AppState`
/// stays within the file/type length limits.
extension AppState {

    /// How many recent Sent messages to sample when learning.
    static let voiceSampleLimit = 12

    // MARK: - Per-account voice resolution (item 99)

    /// Normalized account key for the focused/active mailbox's voice profile.
    var activeAccountVoiceKey: String {
        SavedMailAccount.normalizedEmail(mailEmail)
    }

    /// The voice profile to draft with for `accountEmail`. Returns the focused
    /// account's in-memory profile when it matches (kept fresh by learn/forget),
    /// otherwise loads that account's per-account profile from persistence. Drafts
    /// for account A therefore never borrow account B's voice (item 99).
    func voiceProfile(forAccountEmail accountEmail: String) -> VoiceProfile? {
        let key = SavedMailAccount.normalizedEmail(accountEmail)
        if key == activeAccountVoiceKey { return voiceProfile }
        return persistence.loadVoiceProfile(accountKey: key)
    }

    /// Refreshes the published focused-account profile after a mailbox focus
    /// change. Background drafts still resolve directly from persistence.
    func reloadPublishedVoiceProfileForFocusedAccount() {
        voiceProfile = persistence.loadVoiceProfile(accountKey: activeAccountVoiceKey)
    }

    /// Whether the prerequisites for learning are met (mail + a usable AI provider).
    var canLearnVoice: Bool {
        isLLMConnected
            && mailCredentials.isComplete
            && (currentLLMProviderAllowsRequests || canAttemptStaleManagedLicenseRefresh)
    }

    /// Samples the Sent folder and derives a voice profile via the LLM.
    func learnVoiceProfile(messageSurface: TransientMessageSurface = .shared) async {
        setVoiceError(nil, for: messageSurface)
        let settingsMessageGeneration = settingsTransientMessageGeneration
        let localDataGeneration = localDataEraseGeneration

        await refreshManagedQuotaIfLicenseStatusStale()
        guard let context = makeVoiceLearningContext(
            messageSurface: messageSurface,
            settingsMessageGeneration: settingsMessageGeneration,
            localDataGeneration: localDataGeneration
        ) else { return }
        let credentials = context.credentials
        let llmConfiguration = context.llmConfiguration

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
            guard isCurrentVoiceContext(context) else {
                reportStaleVoiceLearningError(messageSurface: messageSurface, generation: settingsMessageGeneration)
                return
            }
            guard !bodies.isEmpty else {
                reportVoiceLearningError(
                    "No sent messages found to learn from.",
                    messageSurface: messageSurface,
                    generation: settingsMessageGeneration
                )
                return
            }
            voiceProgress = "Learning your voice from \(bodies.count) message\(bodies.count == 1 ? "" : "s")…"
            let profile = try await makeProfile(fromSentBodies: bodies, llmConfiguration: llmConfiguration)
            guard isCurrentVoiceContext(context) else {
                reportStaleVoiceLearningError(messageSurface: messageSurface, generation: settingsMessageGeneration)
                return
            }
            // Voice is learned per account (item 99): store it under the account it
            // was sampled from, and mirror it into the published profile only when
            // that account is the focused one.
            persistence.saveVoiceProfile(profile, accountKey: SavedMailAccount.normalizedEmail(credentials.email))
            if SavedMailAccount.normalizedEmail(credentials.email) == activeAccountVoiceKey {
                voiceProfile = profile
            }
        } catch {
            await reportVoiceLearningFailure(
                error,
                context: context,
                messageSurface: messageSurface,
                settingsMessageGeneration: settingsMessageGeneration
            )
        }
    }

    /// Clears the learned profile.
    func forgetVoiceProfile(messageSurface: TransientMessageSurface = .shared) {
        do {
            try persistence.removeVoiceProfile(accountKey: activeAccountVoiceKey)
        } catch {
            setVoiceError(Self.voiceMessage(for: error), for: messageSurface)
            return
        }
        voiceProfile = nil
        setVoiceError(nil, for: messageSurface)
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
        guard isLLMConnected, currentLLMProviderAllowsRequests else { return nil }
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

    private func makeVoiceLearningContext(
        messageSurface: TransientMessageSurface,
        settingsMessageGeneration: UInt64,
        localDataGeneration: UInt64
    ) -> VoiceLearningContext? {
        guard let llmConfiguration = currentVoiceLLMConfiguration else {
            reportVoiceLearningError(
                "Connect an AI provider first (Test Connection above).",
                messageSurface: messageSurface,
                generation: settingsMessageGeneration
            )
            return nil
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            reportVoiceLearningError(
                "Connect an email account first.",
                messageSurface: messageSurface,
                generation: settingsMessageGeneration
            )
            return nil
        }
        return VoiceLearningContext(
            credentials: credentials,
            llmConfiguration: llmConfiguration,
            localDataGeneration: localDataGeneration
        )
    }

    private func reportVoiceLearningError(
        _ message: String,
        messageSurface: TransientMessageSurface,
        generation: UInt64
    ) {
        guard isCurrentTransientMessageSurface(messageSurface, generation: generation) else { return }
        setVoiceError(message, for: messageSurface)
    }

    private func reportStaleVoiceLearningError(messageSurface: TransientMessageSurface, generation: UInt64) {
        reportVoiceLearningError(
            Self.staleVoiceLLMConfigurationMessage,
            messageSurface: messageSurface,
            generation: generation
        )
    }

    private func reportVoiceLearningFailure(
        _ error: Error,
        context: VoiceLearningContext,
        messageSurface: TransientMessageSurface,
        settingsMessageGeneration: UInt64
    ) async {
        let wasCurrent = isCurrentVoiceContext(context)
        let signedOut = await reconcileManagedAccountState(
            after: error,
            provider: context.llmConfiguration.provider,
            messageSurface: messageSurface
        )
        let remainsCurrentAfterReconcile = signedOut || isCurrentVoiceContext(context)
        let message = wasCurrent && remainsCurrentAfterReconcile
            ? Self.voiceMessage(for: error)
            : Self.staleVoiceLLMConfigurationMessage
        reportVoiceLearningError(
            message,
            messageSurface: messageSurface,
            generation: settingsMessageGeneration
        )
    }

    private func isCurrentVoiceContext(_ context: VoiceLearningContext) -> Bool {
        if !isCurrentLocalDataGeneration(context.localDataGeneration) {
            return false
        }
        return mailCredentials == context.credentials && currentVoiceLLMConfiguration == context.llmConfiguration
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

private struct VoiceLearningContext {
    let credentials: MailAccountCredentials
    let llmConfiguration: VoiceLLMConfiguration
    let localDataGeneration: UInt64
}
