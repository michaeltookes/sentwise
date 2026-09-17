import SentwiseMail
import Foundation

/// Draft send/save dispatch on `AppState`: approving a preview draft routes to an
/// SMTP send or an IMAP `APPEND` to Drafts. Split out of `AppState+Draft` so both
/// files stay within the file-length limit.
extension AppState {

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
            recordSuccessfulApprovalDispatch(for: draft, sendBehavior: .autoSend)
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
            recordSuccessfulApprovalDispatch(for: draft, sendBehavior: .saveAsDraft)
            draftSavedMessage = "Saved to your Drafts."
            generatedDraft = nil
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
        let eraseGeneration = localDataEraseGeneration
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
            try ensureLocalDataNotErased(since: eraseGeneration)
            recordDispatchFailureActivity(error, for: draft, failureKind: .sendFailed)
            throw error
        }
        try ensureLocalDataNotErased(since: eraseGeneration)
        _ = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
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
        let eraseGeneration = localDataEraseGeneration
        do {
            let currentCredentials = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
            try await mailProvider.appendMessage(
                currentCredentials,
                mailbox: .drafts,
                rfc822: rfc822,
                flags: [.draft]
            )
        } catch {
            try ensureLocalDataNotErased(since: eraseGeneration)
            let kind: ActivityEventKind =
                ResilienceClassifier.classify(error) == .authentication ? .authFailed : .saveFailed
            recordDraftActivity(kind, for: draft, detail: Self.draftMessage(for: error))
            throw error
        }
        try ensureLocalDataNotErased(since: eraseGeneration)
        _ = try draftDispatchCredentialsStillCurrent(credentials, for: draft)
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
