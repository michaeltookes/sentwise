import SentwiseMail
import Foundation

/// Draft-generation actions on `AppState`. Kept in a separate file so `AppState`
/// stays within the file/type length limits.
extension AppState {

    /// Whether a draft can be generated (mail + AI connected).
    var canGenerateDraft: Bool {
        isLLMConnected && mailCredentials.isComplete
    }

    /// Fetches a message's body and generates a reply draft in the user's voice.
    @discardableResult
    func generateDraft(for message: MailMessage, mailbox: Mailbox = .inbox) async -> Draft? {
        let requestGeneration = nextDraftGeneration()
        resetDraftPreviewForGeneration()

        guard mailbox.supportsReplyDrafting else {
            draftError = Self.draftMessage(for: DraftError.unsupportedSourceMailbox)
            return nil
        }
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
            let outcome = try await makeReplyOutcome(context: context, llmConfiguration: llmConfiguration)
            guard isCurrentDraftRequest(requestGeneration, credentials: credentials, llmConfiguration: llmConfiguration) else {
                return nil
            }
            let draft = Self.draftPreview(
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

    /// Builds a watcher-selected reply and appends it to the pending queue. Unlike
    /// `generateDraft`, this avoids Settings preview state.
    @discardableResult
    func draftAndEnqueue(
        _ message: MailMessage,
        mailbox: Mailbox = .inbox,
        requireWatching: Bool = true,
        credentials capturedCredentials: MailAccountCredentials? = nil
    ) async throws -> Bool {
        guard let draft = try await makePendingDraft(
            for: message,
            mailbox: mailbox,
            requireWatching: requireWatching,
            credentials: capturedCredentials
        ) else { return false }
        try enqueuePendingDraft(draft)
        return true
    }

    /// Builds a watcher-style queued draft without persisting it.
    func makePendingDraft(
        for message: MailMessage,
        mailbox: Mailbox = .inbox,
        requireWatching: Bool = true,
        credentials capturedCredentials: MailAccountCredentials? = nil
    ) async throws -> Draft? {
        guard mailbox.supportsReplyDrafting else {
            throw DraftError.unsupportedSourceMailbox
        }
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
            credentials: credentials,
            llmConfiguration: llmConfiguration,
            requireWatching: requireWatching
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
            outcome = try await makeReplyOutcome(context: context, llmConfiguration: llmConfiguration)
        } catch {
            await reconcileManagedAccountState(after: error, provider: llmConfiguration.provider)
            throw error
        }
        guard isCurrentDraftContext(
            credentials: credentials,
            llmConfiguration: llmConfiguration,
            requireWatching: requireWatching
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
            body: Self.body(from: outcome),
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

    var currentDraftLLMConfiguration: DraftLLMConfiguration? {
        guard isLLMConnected else { return nil }
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

    private static func draftPreview(
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
            replySubject: replySubject(for: message.subject),
            body: body(from: outcome),
            model: llmConfiguration.model,
            generatedAt: Date(),
            needsInfo: needsInfo(from: outcome),
            notReplyWorthy: notReplyWorthy(from: outcome)
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
        requireWatching: Bool
    ) -> Bool {
        (!requireWatching || watchStatus == .watching)
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
        llmConfiguration: DraftLLMConfiguration
    ) async throws -> DraftOutcome {
        let profile = voiceProfile
        return try await DraftGenerator().makeDraft(
            replyingTo: context,
            voiceProfile: profile,
            model: llmConfiguration.model
        ) { [llm] request in
            try await llm.complete(
                request,
                provider: llmConfiguration.provider,
                apiKey: llmConfiguration.apiKey,
                baseURL: llmConfiguration.baseURL
            )
        }
    }

    /// Approves the current draft, dispatching on the user's send-behavior
    /// setting: send immediately over SMTP, or save a Gmail draft.
    func approveGeneratedDraft() async {
        switch sendBehavior {
        case .autoSend:
            await sendGeneratedDraft()
        case .saveAsDraft:
            await saveGeneratedDraftToDrafts()
        }
    }

    /// Sends the current generated draft immediately over SMTP.
    func sendGeneratedDraft() async {
        guard !isSendingDraft, !isSavingDraft else { return }

        draftError = nil
        draftSentMessage = nil
        draftSavedMessage = nil

        guard let draft = generatedDraft else { return }
        guard !draft.isFlagged else {
            draftError = Self.draftMessage(for: DraftError.needsUserInput)
            return
        }
        guard draftSourceAllowsReplyDispatch(draft) else {
            draftError = Self.draftMessage(for: DraftError.unsupportedSourceMailbox)
            return
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            draftError = "Connect an email account first."
            return
        }

        isSendingDraft = true
        defer { isSendingDraft = false }

        do {
            try await performSend(draft, credentials: credentials)
            draftSentMessage = "Sent."
            generatedDraft = nil
        } catch {
            draftError = Self.draftMessage(for: error)
        }
    }

    /// Saves the current generated draft to the Drafts mailbox via IMAP APPEND.
    func saveGeneratedDraftToDrafts() async {
        guard !isSavingDraft, !isSendingDraft else { return }

        draftError = nil
        draftSavedMessage = nil

        guard let draft = generatedDraft else { return }
        guard !draft.isFlagged else {
            draftError = Self.draftMessage(for: DraftError.needsUserInput)
            return
        }
        guard draftSourceAllowsReplyDispatch(draft) else {
            draftError = Self.draftMessage(for: DraftError.unsupportedSourceMailbox)
            return
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            draftError = "Connect an email account first."
            return
        }

        isSavingDraft = true
        defer { isSavingDraft = false }

        do {
            try await performSave(draft, credentials: credentials)
            draftSavedMessage = "Saved to your Drafts."
        } catch {
            draftError = Self.draftMessage(for: error)
        }
    }

    /// Sends `draft` over SMTP. Shared by the Settings preview and the approval
    /// queue. Throws `DraftDispatchError.noRecipient` when there is no address.
    func performSend(_ draft: Draft, credentials: MailAccountCredentials) async throws {
        // Build the message once — including its Message-ID — and reuse it across
        // retries, so a transient pre-DATA retry can't produce two distinct
        // messages. The SMTP layer only reports pre-DATA drops as retryable, so
        // this loop never re-sends after a message may have been accepted (item 27).
        let outgoing = Self.outgoingMessage(
            for: draft,
            from: credentials.email,
            date: Date(),
            messageID: Self.generateMessageID(forEmail: credentials.email)
        )
        let rfc822 = outgoing.rfc822()
        do {
            guard !outgoing.to.isEmpty else { throw DraftDispatchError.noRecipient }
            try await withResilientRetry {
                let currentCredentials = try self.draftDispatchCredentialsStillCurrent(credentials, for: draft)
                try await self.mailProvider.sendMessage(
                    currentCredentials,
                    rfc822: rfc822,
                    envelope: SMTPEnvelope(sender: credentials.email, recipients: outgoing.to)
                )
            }
        } catch {
            recordDispatchFailureActivity(error, for: draft, failureKind: .sendFailed)
            throw error
        }
        recordDraftActivity(.approvedSent, for: draft, detail: Self.editedBeforeSendDetail(for: draft))
    }

    /// Saves `draft` to the Drafts mailbox. Shared by the Settings preview and
    /// the approval queue.
    func performSave(_ draft: Draft, credentials: MailAccountCredentials) async throws {
        let outgoing = Self.outgoingMessage(
            for: draft,
            from: credentials.email,
            date: Date(),
            messageID: Self.generateMessageID(forEmail: credentials.email)
        )
        let rfc822 = outgoing.rfc822()
        do {
            let currentCredentials = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
            try await mailProvider.appendMessage(
                currentCredentials,
                mailbox: .drafts,
                rfc822: rfc822,
                flags: [.draft]
            )
        } catch {
            let kind: ActivityEventKind =
                ResilienceClassifier.classify(error) == .authentication ? .authFailed : .saveFailed
            recordDraftActivity(kind, for: draft, detail: Self.draftMessage(for: error))
            throw error
        }
        recordDraftActivity(.approvedSaved, for: draft, detail: Self.editedBeforeSendDetail(for: draft))
    }

    /// The activity-log note for an approved draft that the user edited before
    /// dispatching (item 19), or `nil` when the assistant's body was sent as-is.
    /// Metadata only — never the draft content itself, per the activity log's
    /// privacy rule.
    static func editedBeforeSendDetail(for draft: Draft) -> String? {
        draft.wasEdited ? "Edited before send" : nil
    }

    func draftSourceAllowsReplyDispatch(_ draft: Draft) -> Bool {
        guard let sourceMailbox = draft.sourceMailbox else { return true }
        let normalized = sourceMailbox.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !Self.outgoingDraftSourceMailboxes.contains(normalized)
    }

    private static let outgoingDraftSourceMailboxes: Set<String> = [
        Mailbox.sent.imapName.lowercased(),
        Mailbox.drafts.imapName.lowercased(),
        "sent",
        "sent mail",
        "draft",
        "drafts"
    ]

    static func replySubject(for subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("re:") ? trimmed : "Re: \(trimmed)"
    }

    /// Bounds the incoming body kept for the approval preview so the persisted
    /// queue stays small; the full message is re-fetchable from the server.
    static func truncatedIncomingBody(_ text: String, maxChars: Int = 4000) -> String {
        text.count > maxChars ? String(text.prefix(maxChars)) + "…" : text
    }

}

struct DraftLLMConfiguration: Equatable {
    let provider: LLMProviderKind
    let model: String
    let apiKey: String
    let baseURL: String?
}
