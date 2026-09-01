import SentwiseMail
import Foundation

enum FollowUpCommitError: LocalizedError {
    case sourceChanged
    case pendingDraftPersistenceFailed(Error)

    var errorDescription: String? {
        switch self {
        case .sourceChanged:
            return "The transcript changed before the follow-up could be queued."
        case .pendingDraftPersistenceFailed(let error):
            return "Couldn't save the generated follow-up. \(error.localizedDescription)"
        }
    }
}

/// Post-call follow-up actions on `AppState` (item 51): ingest a transcript,
/// draft a follow-up in the user's voice, and route it through the existing
/// approval → send/save pipeline as an *authored* draft (no source message).
extension AppState {

    /// Whether a follow-up can be drafted right now (mail + AI connected),
    /// mirroring `canGenerateDraft`.
    var canCreateFollowUp: Bool {
        isLLMConnected && mailCredentials.isComplete
    }

    /// Drafts a follow-up from an ingested transcript and enqueues it for review.
    /// Recipients are optional here — they are editable in review before approval
    /// (auto-fill is item 52's job) — so the watched-folder path can enqueue with
    /// none and the composer can pre-fill them. Returns the enqueued draft.
    @discardableResult
    func createFollowUp(
        from ingested: IngestedTranscript,
        recipients: [MailAddress] = [],
        subject: String? = nil,
        shouldCommit: (() -> Bool)? = nil
    ) async throws -> Draft {
        guard let llmConfiguration = currentDraftLLMConfiguration else {
            throw DraftError.llmUnavailable
        }
        let credentials = mailCredentials
        guard credentials.isComplete else {
            throw DraftDispatchError.missingCredentials
        }
        let parsed = ingested.parsed()
        guard !parsed.isEmpty else { throw DraftError.emptyDraft }

        let generation: FollowUpGeneration
        do {
            generation = try await makeFollowUpGeneration(parsed: parsed, llmConfiguration: llmConfiguration)
        } catch {
            await reconcileManagedAccountState(after: error, provider: llmConfiguration.provider)
            throw error
        }
        guard mailCredentials == credentials,
              currentDraftLLMConfiguration == llmConfiguration else {
            throw DraftDispatchError.accountChanged
        }
        if let shouldCommit, !shouldCommit() {
            throw FollowUpCommitError.sourceChanged
        }
        let draft = makeAuthoredDraft(AuthoredDraftSpec(
            outcome: generation.outcome,
            recipients: Self.dedupedRecipients(recipients),
            subject: Self.followUpSubject(subject, suggestedTitle: ingested.suggestedTitle),
            model: llmConfiguration.model,
            credentials: credentials,
            followUpContext: generation.context
        ))
        do {
            try enqueuePendingDraft(draft)
        } catch {
            throw FollowUpCommitError.pendingDraftPersistenceFailed(error)
        }
        if let shouldCommit, !shouldCommit() {
            try rollbackPendingFollowUp(draft)
            throw FollowUpCommitError.sourceChanged
        }
        return draft
    }

    /// Applies edited recipients to a queued authored follow-up (item 51) and
    /// persists them, so the review card's recipient list is what actually
    /// dispatches and survives relaunch. Returns the updated draft, the unchanged
    /// draft when identical, or `nil` if it could not be applied durably.
    @discardableResult
    func updatePendingDraftRecipients(_ draft: Draft, to recipients: [MailAddress]) -> Draft? {
        guard let index = pendingDrafts.firstIndex(where: { $0.identity == draft.identity }) else {
            clearPendingDraftEdits(identity: draft.identity)
            return nil
        }
        guard pendingDrafts[index].isAuthored else { return pendingDrafts[index] }
        guard pendingDrafts[index].offlineQueuedDispatch == nil,
              offlineQueuedDispatch[draft.identity] == nil,
              !isWaitingForNetwork(draft.identity) else {
            return pendingDrafts[index]
        }
        let deduped = Self.dedupedRecipients(recipients)
        guard pendingDrafts[index].authoredRecipients != deduped else {
            clearPendingDraftRecipientEdit(identity: draft.identity)
            return pendingDrafts[index]
        }

        let previous = pendingDrafts[index]
        pendingDrafts[index].authoredRecipients = deduped
        pendingDrafts[index].sourceFrom = deduped.first
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts[index] = previous
            pendingDraftUncommittedEditIDs.insert(draft.identity)
            pendingDraftUncommittedEditRecipients[draft.identity] = deduped
            pendingDraftInvalidRecipientEditIDs.remove(draft.identity)
            approvalError = Self.draftMessage(for: error)
            return nil
        }
        clearPendingDraftRecipientEdit(identity: draft.identity)
        notifier.refreshNotification(for: pendingDrafts[index], sendBehavior: sendBehavior)
        return pendingDrafts[index]
    }

    // MARK: - Helpers

    func makeFollowUpOutcome(
        parsed: ParsedTranscript,
        llmConfiguration: DraftLLMConfiguration,
        userSuppliedFacts: UserSuppliedFacts? = nil
    ) async throws -> DraftOutcome {
        try await makeFollowUpGeneration(
            parsed: parsed,
            llmConfiguration: llmConfiguration,
            userSuppliedFacts: userSuppliedFacts
        ).outcome
    }

    func makeFollowUpGeneration(
        parsed: ParsedTranscript,
        llmConfiguration: DraftLLMConfiguration,
        userSuppliedFacts: UserSuppliedFacts? = nil
    ) async throws -> FollowUpGeneration {
        let profile = voiceProfile
        let runner = retryRunner
        return try await FollowUpGenerator().makeFollowUpGeneration(
            transcript: parsed,
            voiceProfile: profile,
            model: llmConfiguration.model,
            userSuppliedFacts: userSuppliedFacts
        ) { [llm] request in
            try await runner.run(classify: ResilienceClassifier.retryDecision(for:)) {
                try await llm.complete(
                    request,
                    provider: llmConfiguration.provider,
                    apiKey: llmConfiguration.apiKey,
                    baseURL: llmConfiguration.baseURL
                )
            }
        }
    }

    func makeFollowUpOutcome(
        context: FollowUpDraftContext,
        llmConfiguration: DraftLLMConfiguration,
        userSuppliedFacts: UserSuppliedFacts? = nil
    ) async throws -> DraftOutcome {
        let profile = voiceProfile
        let runner = retryRunner
        return try await FollowUpGenerator().makeFollowUp(
            from: context,
            voiceProfile: profile,
            model: llmConfiguration.model,
            userSuppliedFacts: userSuppliedFacts
        ) { [llm] request in
            try await runner.run(classify: ResilienceClassifier.retryDecision(for:)) {
                try await llm.complete(
                    request,
                    provider: llmConfiguration.provider,
                    apiKey: llmConfiguration.apiKey,
                    baseURL: llmConfiguration.baseURL
                )
            }
        }
    }

    struct AuthoredDraftSpec {
        var outcome: DraftOutcome
        var recipients: [MailAddress]
        var subject: String
        var model: String
        var credentials: MailAccountCredentials
        var followUpContext: FollowUpDraftContext
        var id: UInt32?
    }

    func makeAuthoredDraft(_ spec: AuthoredDraftSpec) -> Draft {
        Draft(
            id: spec.id ?? uniqueAuthoredDraftID(),
            sourceUIDValidity: nil,
            sourceAccountEmail: spec.credentials.email,
            sourceMailHost: spec.credentials.host,
            sourceMailPort: spec.credentials.port,
            sourceMailbox: nil,
            sourceSubject: spec.subject,
            // Mirror the first recipient into sourceFrom so the review card and
            // notification can show a name; recipients drive actual dispatch.
            sourceFrom: spec.recipients.first,
            sourceReplyTo: nil,
            sourceMessageID: nil,
            incomingBody: Self.truncatedIncomingBody(spec.followUpContext.text),
            replySubject: spec.subject,
            body: finalizedDraftBody(Self.body(from: spec.outcome)),
            model: spec.model,
            generatedAt: Date(),
            needsInfo: Self.needsInfo(from: spec.outcome),
            notReplyWorthy: Self.notReplyWorthy(from: spec.outcome),
            authoredRecipients: spec.recipients,
            followUpContext: spec.followUpContext
        )
    }

    static let maxPersistedFollowUpContextChars = FollowUpGenerator().maxSinglePassChars

    func rollbackPendingFollowUp(_ draft: Draft) throws {
        let previousDrafts = pendingDrafts
        guard pendingDrafts.contains(where: { $0.identity == draft.identity }) else { return }
        pendingDrafts.removeAll { $0.identity == draft.identity }
        pendingDraftCount = pendingDrafts.count
        do {
            try persistence.savePendingDraftsSync(pendingDrafts)
        } catch {
            pendingDrafts = previousDrafts
            pendingDraftCount = previousDrafts.count
            throw error
        }
        notifier.removeNotification(identity: draft.identity)
        clearPendingDraftEdits(identity: draft.identity)
    }

    /// A synthetic id that doesn't collide with any queued draft. Authored drafts
    /// have no IMAP UID, so their `identity` is `account|?|?|id` — uniqueness of
    /// `id` among pending drafts is enough to keep it distinct.
    private func uniqueAuthoredDraftID() -> UInt32 {
        let existing = Set(pendingDrafts.map(\.id))
        var candidate = UInt32.random(in: 1...UInt32.max)
        while existing.contains(candidate) {
            candidate = UInt32.random(in: 1...UInt32.max)
        }
        return candidate
    }

    static func followUpSubject(_ provided: String?, suggestedTitle: String?) -> String {
        if let provided = provided.map(sanitizedFollowUpSubjectText), !provided.isEmpty {
            return provided
        }
        if let title = suggestedTitle.map(sanitizedFollowUpSubjectText), !title.isEmpty {
            return "Follow-up: \(title)"
        }
        return "Post-call follow-up"
    }

    private static func sanitizedFollowUpSubjectText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Parses a free-form recipients string (comma/semicolon/newline separated,
    /// tolerating `Name <email>` and space-separated addresses) into unique,
    /// syntactically plausible addresses.
    static func parseRecipients(_ text: String) -> [MailAddress] {
        parseRecipientEdit(text).recipients
    }

    struct RecipientParseResult: Equatable {
        var recipients: [MailAddress]
        var hasInvalidEntries: Bool
    }

    static func parseRecipientEdit(_ text: String) -> RecipientParseResult {
        var addresses: [MailAddress] = []
        var hasInvalidEntries = false
        for entry in text.components(separatedBy: CharacterSet(charactersIn: ",;\r\n")) {
            let parsed = parseRecipientEntry(entry)
            addresses.append(contentsOf: parsed.emails.map { MailAddress(email: $0) })
            hasInvalidEntries = hasInvalidEntries || parsed.isInvalid
        }
        return RecipientParseResult(
            recipients: dedupedRecipients(addresses),
            hasInvalidEntries: hasInvalidEntries
        )
    }

    static func dedupedRecipients(_ recipients: [MailAddress]) -> [MailAddress] {
        var seen = Set<String>()
        return recipients.filter { seen.insert($0.email.lowercased()).inserted }
    }

    private static func parseRecipientEntry(_ entry: String) -> (emails: [String], isInvalid: Bool) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ([], false) }
        if let start = trimmed.lastIndex(of: "<"), let end = trimmed.lastIndex(of: ">"), start < end {
            let inner = String(trimmed[trimmed.index(after: start)..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trailingText = trimmed[trimmed.index(after: end)...].trimmingCharacters(in: .whitespaces)
            return isLikelyEmail(inner) && trailingText.isEmpty ? ([inner], false) : ([], true)
        }
        if trimmed.contains("<") || trimmed.contains(">") {
            return ([], true)
        }
        var emails: [String] = []
        var isInvalid = false
        for token in trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            if isLikelyEmail(token) {
                emails.append(token)
            } else {
                isInvalid = true
            }
        }
        return (emails, isInvalid)
    }

    static func isLikelyEmail(_ token: String) -> Bool {
        let invalidCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard token.rangeOfCharacter(from: invalidCharacters) == nil else { return false }
        let parts = token.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}
