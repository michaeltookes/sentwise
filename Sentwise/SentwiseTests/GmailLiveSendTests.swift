import SentwiseMail
import XCTest
@testable import Sentwise

/// Live end-to-end verification of the SMTP auto-send path against a real Gmail
/// account — the counterpart to `AttNetLiveDraftTests` and the remaining
/// unchecked criterion of backlog item 9. Follows the user's standing QA
/// preference for a headless XCTest integration test over a manual click-through.
///
/// **Credential-gated:** the test SKIPS cleanly unless real Gmail credentials
/// are supplied through environment variables, so it never fails in CI or on a
/// developer machine without a live account:
///
///   - `SENTWISE_LIVE_GMAIL_EMAIL`         — the Gmail address (required)
///   - `SENTWISE_LIVE_GMAIL_APP_PASSWORD`  — its 16-char app password (required)
///   - `SENTWISE_LIVE_GMAIL_HOST`          — IMAP host (optional; default imap.gmail.com)
///   - `SENTWISE_LIVE_GMAIL_PORT`          — IMAP port (optional; default 993)
///
/// See `docs/live-verification.md` for how these reach the test process under
/// `xcodebuild test` (the `TEST_RUNNER_` prefix) and the exact invocation.
///
/// When credentials ARE present it: dispatches a reply through the app's real
/// auto-send path (`performSend` → SMTP submission over implicit TLS on the
/// derived `smtp.` host), fetches the delivered copy back from the inbox to
/// assert addressing and threading headers, confirms Gmail auto-filed a copy in
/// Sent Mail, then moves every test copy to Trash so the mailbox is left clean.
/// The reply is **strictly self-addressed** — the recipient is the account's own
/// address — so nothing is ever deliverable to a third party.
@MainActor
final class GmailLiveSendTests: XCTestCase {

    /// How long to wait for Gmail to make the just-sent message visible over IMAP.
    private let deliveryPollAttempts = 12
    private let deliveryPollInterval: UInt64 = 3_000_000_000 // 3s

    private func liveCredentials() throws -> MailAccountCredentials {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SENTWISE_LIVE_GMAIL_EMAIL"], !email.isEmpty,
              let password = env["SENTWISE_LIVE_GMAIL_APP_PASSWORD"], !password.isEmpty else {
            throw XCTSkip(
                "Set SENTWISE_LIVE_GMAIL_EMAIL and SENTWISE_LIVE_GMAIL_APP_PASSWORD "
                + "to run the Gmail live send test."
            )
        }
        let host = env["SENTWISE_LIVE_GMAIL_HOST"] ?? "imap.gmail.com"
        let port = env["SENTWISE_LIVE_GMAIL_PORT"].flatMap(Int.init) ?? 993
        return MailAccountCredentials(email: email, appPassword: password, host: host, port: port)
    }

    func testAutoSentReplyIsDeliveredCorrectlyAddressedAndThreaded() async throws {
        let credentials = try liveCredentials()
        let provider = LiveMailProvider.imapProvider()

        // A unique marker so we find and clean up exactly our own test message.
        let marker = UUID().uuidString
        let subject = "Sentwise item9 live test \(marker)"
        // Self-addressed: the reply recipient is our own account, so the SMTP
        // dispatch can never deliver anything to a third party.
        let recipient = credentials.email
        let originalMessageID = "<original-\(marker)@gmail.com>"

        let draft = Draft(
            id: 1,
            sourceUIDValidity: nil,
            sourceAccountEmail: credentials.email,
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: subject,
            sourceFrom: MailAddress(email: recipient),
            sourceReplyTo: nil,
            sourceMessageID: originalMessageID,
            replySubject: subject,
            body: "Automated item-9 verification message. Safe to delete.",
            model: "live-test",
            generatedAt: Date()
        )

        let app = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore(),
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        app.mailEmail = credentials.email
        app.mailAppPassword = credentials.appPassword
        app.mailHost = credentials.host
        app.mailPort = credentials.port

        do {
            // Dispatch through the app's real auto-send path (SMTP submission on the
            // derived smtp. host, implicit TLS 465 — the same call `approve` makes).
            try await app.performSend(draft, credentials: credentials)

            try await verifyDeliveredMessage(
                provider: provider,
                credentials: credentials,
                marker: marker,
                recipient: recipient,
                originalMessageID: originalMessageID
            )
        } catch {
            await cleanUpAfterPotentialSubmissionError(
                provider: provider,
                credentials: credentials,
                marker: marker
            )
            throw error
        }

        try await cleanUpTestMessages(provider: provider, credentials: credentials, marker: marker)
    }

    private func verifyDeliveredMessage(
        provider: IMAPMailProvider,
        credentials: MailAccountCredentials,
        marker: String,
        recipient: String,
        originalMessageID: String
    ) async throws {
        // Self-addressed mail lands in the inbox; poll for it since delivery has
        // some latency before the message becomes visible over IMAP.
        let delivered = try await waitForMessage(
            provider: provider,
            credentials: credentials,
            mailbox: .inbox,
            marker: marker
        )
        let inbox = try XCTUnwrap(delivered, "the auto-sent reply should be delivered to the inbox")

        XCTAssertTrue(
            inbox.to.contains { $0.email.caseInsensitiveCompare(recipient) == .orderedSame },
            "delivered message should be addressed to the reply recipient"
        )
        XCTAssertTrue(inbox.subject.contains(marker), "delivered message should carry the marker subject")
        XCTAssertEqual(inbox.inReplyTo, originalMessageID, "delivered message should thread via In-Reply-To")

        // Gmail auto-files SMTP submissions in Sent Mail — confirm our copy is there.
        let sent = try await waitForMessage(
            provider: provider,
            credentials: credentials,
            mailbox: .sent,
            marker: marker
        )
        let sentCopy = try XCTUnwrap(sent, "Gmail should file a copy of the sent reply in Sent Mail")
        XCTAssertTrue(
            sentCopy.to.contains { $0.email.caseInsensitiveCompare(recipient) == .orderedSame },
            "the Sent Mail copy should be addressed to the reply recipient"
        )
    }

    /// Polls `mailbox` for a message whose subject contains `marker`, returning it
    /// once found or `nil` if it never appears within the delivery window.
    private func waitForMessage(
        provider: IMAPMailProvider,
        credentials: MailAccountCredentials,
        mailbox: Mailbox,
        marker: String
    ) async throws -> MailMessage? {
        for attempt in 0..<deliveryPollAttempts {
            let found = try await provider.searchMessages(
                credentials,
                mailbox: mailbox,
                criteria: MailSearchCriteria(subject: marker),
                offset: 0,
                limit: 10
            )
            if let match = found.messages.first(where: { $0.subject.contains(marker) }) {
                return match
            }
            if attempt < deliveryPollAttempts - 1 {
                try await Task.sleep(nanoseconds: deliveryPollInterval)
            }
        }
        return nil
    }

    private func cleanUpAfterPotentialSubmissionError(
        provider: IMAPMailProvider,
        credentials: MailAccountCredentials,
        marker: String
    ) async {
        do {
            try await cleanUpTestMessagesAfterDeliveryWindow(
                provider: provider,
                credentials: credentials,
                marker: marker
            )
        } catch {
            XCTFail("Failed to clean up Gmail live test messages after test error: \(error.localizedDescription)")
        }
    }

    /// Moves every test copy (Inbox and Sent Mail) to Trash so the real mailbox is
    /// left clean, then asserts both folders no longer show the marker. (Trash
    /// keeps them recoverable, matching item 42's non-destructive delete.)
    private func cleanUpTestMessages(
        provider: IMAPMailProvider,
        credentials: MailAccountCredentials,
        marker: String
    ) async throws {
        try await moveTestMessagesToTrash(provider: provider, credentials: credentials, marker: marker)
        try await assertTestMessagesRemoved(provider: provider, credentials: credentials, marker: marker)
    }

    private func cleanUpTestMessagesAfterDeliveryWindow(
        provider: IMAPMailProvider,
        credentials: MailAccountCredentials,
        marker: String
    ) async throws {
        var latestCleanupError: Error?

        for attempt in 0..<deliveryPollAttempts {
            do {
                try await moveTestMessagesToTrash(provider: provider, credentials: credentials, marker: marker)
                latestCleanupError = nil
            } catch {
                // Keep polling through transient IMAP failures; a later attempt may
                // still catch an ambiguously accepted SMTP submission once visible.
                latestCleanupError = error
            }

            if attempt < deliveryPollAttempts - 1 {
                try await Task.sleep(nanoseconds: deliveryPollInterval)
            }
        }

        do {
            try await assertTestMessagesRemoved(provider: provider, credentials: credentials, marker: marker)
        } catch {
            throw latestCleanupError ?? error
        }
    }

    private func moveTestMessagesToTrash(
        provider: IMAPMailProvider,
        credentials: MailAccountCredentials,
        marker: String
    ) async throws {
        // Trash the inbox copy first. On Gmail a self-addressed message is a single
        // labelled message, so this may also clear its Sent label; the Sent pass
        // then simply finds nothing, which is fine.
        for mailbox in [Mailbox.inbox, Mailbox.sent] {
            _ = try await provider.applyBulkCleanup(
                credentials,
                mailbox: mailbox,
                criteria: MailSearchCriteria(subject: marker),
                action: .moveToTrash,
                selectionCap: 50,
                onProgress: nil
            )
        }
    }

    private func assertTestMessagesRemoved(
        provider: IMAPMailProvider,
        credentials: MailAccountCredentials,
        marker: String
    ) async throws {
        for mailbox in [Mailbox.inbox, Mailbox.sent] {
            let after = try await provider.searchMessages(
                credentials,
                mailbox: mailbox,
                criteria: MailSearchCriteria(subject: marker),
                offset: 0,
                limit: 10
            )
            XCTAssertFalse(
                after.messages.contains { $0.subject.contains(marker) },
                "the test message should be removed from \(mailbox.imapName) after cleanup"
            )
        }
    }
}
