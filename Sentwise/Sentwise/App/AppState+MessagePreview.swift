import SentwiseMail
import Foundation

/// On-demand message-preview actions on `AppState` (Settings "Recent messages"
/// and "View body"). Kept in a separate file so `AppState` stays within the
/// file/type length limits. Each action is guarded by a monotonic generation
/// counter so a stale completion (after an account change or a newer request)
/// never clobbers current state.
extension AppState {

    /// Fetches recent messages from a mailbox for a quick preview.
    func previewRecentMessages(mailbox: Mailbox = .inbox, limit: Int = 10) async {
        let requestGeneration = nextPreviewGeneration()
        _ = nextBodyPreviewGeneration()
        _ = nextDraftGeneration()
        clearRecentMessagePreview()
        clearDraftPreview()
        isFetching = false
        isFetchingBody = false
        isGeneratingDraft = false

        let credentials = mailCredentials
        guard credentials.isComplete else {
            fetchError = "Connect an account first."
            return
        }

        isFetching = true
        defer {
            if previewGeneration == requestGeneration {
                isFetching = false
            }
        }

        do {
            let messages = try await mailProvider.fetchRecentMessages(
                credentials,
                mailbox: mailbox,
                limit: limit
            )
            guard isCurrentPreviewRequest(requestGeneration, credentials: credentials) else { return }
            recentMessages = messages
        } catch {
            guard isCurrentPreviewRequest(requestGeneration, credentials: credentials) else { return }
            recentMessages = []
            fetchError = Self.message(for: error)
        }
    }

    /// Fetches and reduces a single message's body to readable text for preview.
    @discardableResult
    func previewBody(for message: MailMessage, mailbox: Mailbox = .inbox) async -> MailBodyPreview? {
        let requestGeneration = nextBodyPreviewGeneration()
        bodyError = nil
        openedBody = nil
        isFetchingBody = false

        let credentials = mailCredentials
        guard credentials.isComplete else {
            bodyError = "Connect an account first."
            return nil
        }

        isFetchingBody = true
        defer {
            if bodyPreviewGeneration == requestGeneration {
                isFetchingBody = false
            }
        }

        do {
            let preview = try await fetchBodyPreview(for: message, mailbox: mailbox, credentials: credentials)
            guard isCurrentBodyPreviewRequest(requestGeneration, credentials: credentials) else { return nil }
            openedBody = preview
            return preview
        } catch {
            guard isCurrentBodyPreviewRequest(requestGeneration, credentials: credentials) else { return nil }
            bodyError = Self.message(for: error)
            return nil
        }
    }

    /// Fetches and reduces a body preview without mutating shared presentation state.
    func fetchBodyPreview(
        for message: MailMessage,
        mailbox: Mailbox = .inbox,
        credentials: MailAccountCredentials
    ) async throws -> MailBodyPreview {
        let raw = try await mailProvider.fetchBodyText(
            credentials,
            mailbox: mailbox,
            uid: message.id,
            expectedUIDValidity: message.uidValidity
        )
        return MailBodyPreview(
            id: message.id,
            subject: message.subject,
            text: MailBodyText.plainText(from: raw)
        )
    }

    func nextPreviewGeneration() -> Int {
        previewGeneration += 1
        return previewGeneration
    }

    func nextBodyPreviewGeneration() -> Int {
        bodyPreviewGeneration += 1
        return bodyPreviewGeneration
    }

    func resetMessagePreviewForAccountChange(clearSkippedMessages shouldClearSkippedMessages: Bool = true) {
        _ = nextPreviewGeneration()
        _ = nextBodyPreviewGeneration()
        _ = nextDraftGeneration()
        clearRecentMessagePreview()
        clearDraftPreview()
        resetMailboxBrowserForAccountChange()
        resetBulkCleanupForAccountChange()
        if shouldClearSkippedMessages {
            restoreSkippedMessagesFromPersistence()
        }
        isFetching = false
        isFetchingBody = false
        isGeneratingDraft = false
    }

    private func clearRecentMessagePreview() {
        recentMessages = []
        fetchError = nil
        openedBody = nil
        bodyError = nil
    }

    private func isCurrentPreviewRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials
    ) -> Bool {
        previewGeneration == requestGeneration && mailCredentials == credentials
    }

    private func isCurrentBodyPreviewRequest(
        _ requestGeneration: Int,
        credentials: MailAccountCredentials
    ) -> Bool {
        bodyPreviewGeneration == requestGeneration && mailCredentials == credentials
    }
}
