import SentwiseMail
import Foundation

/// Draft-generation actions on `AppState`. Kept in a separate file so `AppState`
/// stays within the file/type length limits.
extension AppState {

    /// Whether a draft can be generated (mail + a usable AI provider).
    var canGenerateDraft: Bool {
        isLLMConnected
            && mailCredentials.isComplete
            && (currentLLMProviderAllowsRequests || canAttemptStaleManagedLicenseRefresh)
    }

    /// Fetches a message's body and generates a reply draft in the user's voice.
    @discardableResult
    func generateDraft(for message: MailMessage, mailbox: Mailbox = .inbox) async -> Draft? {
        let requestGeneration = prepareDraftGeneration()

        guard mailbox.supportsReplyDrafting else {
            draftError = Self.draftMessage(for: DraftError.unsupportedSourceMailbox)
            return nil
        }
        await refreshManagedQuotaIfLicenseStatusStale()
        guard let llmConfiguration = currentDraftLLMConfiguration else {
            draftError = "Connect an AI provider first (Test Connection above)."
            return nil
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            draftError = "Connect an email account first."
            return nil
        }

        isGeneratingDraft = true
        defer {
            if isLatestDraftRequest(requestGeneration) {
                isGeneratingDraft = false
            }
        }

        do {
            let data = try await mailProvider.fetchBodyText(
                credentials,
                mailbox: mailbox,
                uid: message.id,
                expectedUIDValidity: message.uidValidity
            )
            guard isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration) else {
                return nil
            }
            let context = ReplyContext(
                senderName: message.from?.name,
                senderEmail: message.from?.email,
                subject: message.subject,
                body: MailBodyText.plainText(from: data)
            )
            let outcome = try await makeReplyOutcome(context: context, llmConfiguration: llmConfiguration, accountEmail: credentials.email)
            guard isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration) else {
                return nil
            }
            let draft = draftPreview(
                for: message,
                outcome: outcome,
                llmConfiguration: llmConfiguration,
                credentials: credentials,
                mailbox: mailbox
            )
            generatedDraft = draft
            recordDraftActivity(.draftCreated, for: draft)
            return draft
        } catch {
            let wasCurrent = isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration)
            let signedOut = await reconcileManagedAccountState(after: error, provider: llmConfiguration.provider)
            guard wasCurrent,
                  signedOut || isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration)
            else { return nil }
            draftError = Self.draftMessage(for: error)
            return nil
        }
    }

    /// Builds a watcher-style queued draft without persisting it.
    func makePendingDraft(
        for message: MailMessage,
        mailbox: Mailbox = .inbox,
        requireWatching: Bool = true,
        credentials capturedCredentials: MailAccountCredentials? = nil,
        userSuppliedFacts: UserSuppliedFacts? = nil,
        localDataGeneration: UInt64? = nil
    ) async throws -> Draft? {
        guard mailbox.supportsReplyDrafting else {
            throw DraftError.unsupportedSourceMailbox
        }
        await refreshManagedQuotaIfLicenseStatusStale()
        guard let llmConfiguration = currentDraftLLMConfiguration else {
            throw DraftError.emptyDraft
        }
        let credentials = capturedCredentials ?? mailCredentials
        let data = try await mailProvider.fetchBodyText(
            credentials,
            mailbox: mailbox,
            uid: message.id,
            expectedUIDValidity: message.uidValidity
        )
        guard isCurrentDraftContext(
            credentials: credentials, llmConfiguration: llmConfiguration, requireWatching: requireWatching,
            localDataGeneration: localDataGeneration
        ) else { return nil }
        let incomingText = MailBodyText.plainText(from: data)
        let context = ReplyContext(
            senderName: message.from?.name,
            senderEmail: message.from?.email,
            subject: message.subject,
            body: incomingText
        )
        let outcome: DraftOutcome
        do {
            outcome = try await makeReplyOutcome(
                context: context,
                llmConfiguration: llmConfiguration,
                accountEmail: credentials.email,
                userSuppliedFacts: userSuppliedFacts)
        } catch {
            await reconcileManagedAccountState(after: error, provider: llmConfiguration.provider)
            throw error
        }
        guard isCurrentDraftContext(
            credentials: credentials, llmConfiguration: llmConfiguration, requireWatching: requireWatching,
            localDataGeneration: localDataGeneration
        ) else { return nil }
        let draft = Draft(
            id: message.id,
            sourceUIDValidity: message.uidValidity,
            sourceAccountEmail: credentials.email,
            sourceMailHost: credentials.host,
            sourceMailPort: credentials.port,
            sourceMailbox: mailbox.imapName,
            sourceSubject: message.subject,
            sourceFrom: message.from,
            sourceReplyTo: message.replyTo,
            sourceMessageID: message.messageID,
            incomingBody: Self.truncatedIncomingBody(incomingText),
            replySubject: Self.replySubject(for: message.subject),
            body: finalizedDraftBody(Self.body(from: outcome)),
            model: llmConfiguration.model,
            generatedAt: Date(),
            needsInfo: Self.needsInfo(from: outcome),
            notReplyWorthy: Self.notReplyWorthy(from: outcome)
        )
        return draft
    }

    // MARK: - Helpers

    func nextDraftGeneration() -> Int {
        draftGeneration += 1
        return draftGeneration
    }

    func clearDraftPreview() {
        generatedDraft = nil
        draftError = nil
        draftSavedMessage = nil
        draftSentMessage = nil
    }

    func resetDraftPreviewForLLMChange() {
        _ = nextDraftGeneration()
        clearDraftPreview()
        isGeneratingDraft = false
    }

    private func resetDraftPreviewForGeneration() {
        bodyError = nil
        clearDraftPreview()
        isGeneratingDraft = false
    }

    private func prepareDraftGeneration() -> Int {
        let requestGeneration = nextDraftGeneration()
        resetDraftPreviewForGeneration()
        return requestGeneration
    }

    var currentDraftLLMConfiguration: DraftLLMConfiguration? {
        guard isLLMConnected, currentLLMProviderAllowsRequests else { return nil }
        let key = Self.storedLLMAPIKey(
            provider: llmProviderKind,
            baseURL: currentLLMBaseURL,
            secrets: secrets
        )
        // Key-optional providers (local runtimes) draft with an empty key; cloud
        // providers still require a stored key.
        guard !key.isEmpty || !llmProviderKind.requiresAPIKey else { return nil }
        return DraftLLMConfiguration(
            provider: llmProviderKind,
            model: resolvedLLMModel,
            apiKey: key,
            baseURL: currentLLMBaseURL
        )
    }

    private func draftPreview(
        for message: MailMessage,
        outcome: DraftOutcome,
        llmConfiguration: DraftLLMConfiguration,
        credentials: MailAccountCredentials,
        mailbox: Mailbox
    ) -> Draft {
        Draft(
            id: message.id,
            sourceUIDValidity: message.uidValidity,
            sourceAccountEmail: credentials.email,
            sourceMailHost: credentials.host,
            sourceMailPort: credentials.port,
            sourceMailbox: mailbox.imapName,
            sourceSubject: message.subject,
            sourceFrom: message.from,
            sourceReplyTo: message.replyTo,
            sourceMessageID: message.messageID,
            replySubject: Self.replySubject(for: message.subject),
            body: finalizedDraftBody(Self.body(from: outcome)),
            model: llmConfiguration.model,
            generatedAt: Date(),
            needsInfo: Self.needsInfo(from: outcome),
            notReplyWorthy: Self.notReplyWorthy(from: outcome),
            manualPreview: true
        )
    }

    /// The sendable reply body for an outcome; empty for a flagged one, which has
    /// no fabricated reply.
    static func body(from outcome: DraftOutcome) -> String {
        switch outcome {
        case .ready(let body): return body
        case .needsInfo, .notReplyWorthy: return ""
        }
    }

    /// The "needs input" flag for an outcome, or `nil` for a ready reply.
    static func needsInfo(from outcome: DraftOutcome) -> DraftNeedsInfo? {
        switch outcome {
        case .ready: return nil
        case .needsInfo(let info): return info
        case .notReplyWorthy: return nil
        }
    }

    static func notReplyWorthy(from outcome: DraftOutcome) -> DraftNotReplyWorthy? {
        if case .notReplyWorthy(let verdict) = outcome { return verdict }
        return nil
    }

    private func isCurrentDraftRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials,
        llmConfiguration: DraftLLMConfiguration
    ) -> Bool {
        draftGeneration == requestGeneration
            && mailCredentials == credentials
            && currentDraftLLMConfiguration == llmConfiguration
    }

    /// Whether the account/LLM context is still the one an in-flight draft began
    /// with. `requireWatching` additionally demands the watcher still be running
    /// (the watcher path); manual regeneration (item 12) passes `false` so it
    /// works from the review window regardless of watch state.
    private func isCurrentDraftContext(
        credentials: MailAccountCredentials,
        llmConfiguration: DraftLLMConfiguration,
        requireWatching: Bool,
        localDataGeneration: UInt64?
    ) -> Bool {
        if let localDataGeneration, !isCurrentLocalDataGeneration(localDataGeneration) {
            return false
        }
        return (!requireWatching || watchStatus == .watching)
            && mailCredentials == credentials
            && currentDraftLLMConfiguration == llmConfiguration
    }

    func enqueuePendingDraft(_ draft: Draft) throws {
        pendingDrafts.append(draft)
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
            pendingDraftCount = pendingDrafts.count
        } catch {
            pendingDrafts.removeLast()
            pendingDraftCount = pendingDrafts.count
            throw error
        }
        notifier.notify(for: draft, sendBehavior: sendBehavior)
        recordDraftActivity(.draftCreated, for: draft)
    }

    func isLatestDraftRequest(_ requestGeneration: Int) -> Bool {
        draftGeneration == requestGeneration
    }

    private func makeReplyOutcome(
        context: ReplyContext,
        llmConfiguration: DraftLLMConfiguration,
        accountEmail: String,
        userSuppliedFacts: UserSuppliedFacts? = nil
    ) async throws -> DraftOutcome {
        // Per-account voice (item 99): draft in the voice learned from the account
        // the message arrived in, never another account's voice.
        let profile = voiceProfile(forAccountEmail: accountEmail)
        return try await DraftGenerator().makeDraft(
            replyingTo: context,
            voiceProfile: profile,
            model: llmConfiguration.model,
            userSuppliedFacts: userSuppliedFacts
        ) { [llm] request in
            try await llm.complete(
                request,
                provider: llmConfiguration.provider,
                apiKey: llmConfiguration.apiKey,
                baseURL: llmConfiguration.baseURL
            )
        }
    }
}
