import SentwiseMail
import XCTest
@testable import Sentwise

/// Live end-to-end verification of the save-as-draft path against a real att.net
/// (Yahoo-backed) account — the one remaining unchecked criterion of backlog
/// item 44. Follows the user's standing QA preference for a headless XCTest
/// integration test over a manual click-through.
///
/// **Credential-gated:** the test SKIPS cleanly unless real att.net credentials
/// are supplied through environment variables, so it never fails in CI or on a
/// developer machine without a live account:
///
///   - `SENTWISE_LIVE_ATTNET_EMAIL`         — the att.net address (required)
///   - `SENTWISE_LIVE_ATTNET_APP_PASSWORD`  — its AT&T Secure Mail Key (required)
///   - `SENTWISE_LIVE_ATTNET_HOST`          — IMAP host (optional; default imap.mail.att.net)
///   - `SENTWISE_LIVE_ATTNET_PORT`          — IMAP port (optional; default 993)
///
/// When credentials ARE present it: saves a reply draft to the account's real
/// Drafts mailbox through the normal save path, fetches it back to assert the
/// addressing and threading headers, then moves the test draft to Trash so the
/// user's Drafts folder is left clean. The draft is self-addressed, so nothing
/// is ever delivered to a third party.
@MainActor
final class AttNetLiveDraftTests: XCTestCase {

    private func liveCredentials() throws -> MailAccountCredentials {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SENTWISE_LIVE_ATTNET_EMAIL"], !email.isEmpty,
              let password = env["SENTWISE_LIVE_ATTNET_APP_PASSWORD"], !password.isEmpty else {
            throw XCTSkip(
                "Set SENTWISE_LIVE_ATTNET_EMAIL and SENTWISE_LIVE_ATTNET_APP_PASSWORD "
                + "to run the att.net live draft test."
            )
        }
        let host = env["SENTWISE_LIVE_ATTNET_HOST"] ?? "imap.mail.att.net"
        let port = env["SENTWISE_LIVE_ATTNET_PORT"].flatMap(Int.init) ?? 993
        return MailAccountCredentials(email: email, appPassword: password, host: host, port: port)
    }

    func testReplyDraftLandsInAttNetDraftsCorrectlyAddressedAndThreaded() async throws {
        let credentials = try liveCredentials()
        let provider = LiveMailProvider.imapProvider()

        // A unique marker so we find and clean up exactly our own test draft.
        let marker = UUID().uuidString
        let subject = "Sentwise item44 live test \(marker)"
        // Self-addressed: replying "to" our own account so nothing leaves the mailbox.
        let recipient = credentials.email
        let originalMessageID = "<original-\(marker)@att.net>"

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
            body: "Automated item-44 verification draft. Safe to delete.",
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
            // Save through the normal save path (IMAP APPEND to Drafts with \Draft).
            try await app.performSave(draft, credentials: credentials)
            try await verifySavedDraft(
                provider: provider,
                credentials: credentials,
                marker: marker,
                recipient: recipient,
                originalMessageID: originalMessageID
            )
        } catch {
            await cleanUpAfterVerificationError(provider: provider, credentials: credentials, marker: marker)
            throw error
        }

        try await cleanUpTestDraft(provider: provider, credentials: credentials, marker: marker)
    }

    private func verifySavedDraft(
        provider: IMAPMailProvider,
        credentials: MailAccountCredentials,
        marker: String,
        recipient: String,
        originalMessageID: String
    ) async throws {
        // Fetch it back from Drafts and assert addressing + threading.
        let found = try await provider.searchMessages(
            credentials,
            mailbox: .drafts,
            criteria: MailSearchCriteria(subject: marker),
            offset: 0,
            limit: 10
        )
        let saved = try XCTUnwrap(
            found.messages.first { $0.subject.contains(marker) },
            "the saved reply draft should appear in att.net Drafts"
        )

        XCTAssertTrue(
            saved.to.contains { $0.email.caseInsensitiveCompare(recipient) == .orderedSame },
            "draft should be addressed to the reply recipient"
        )
        XCTAssertEqual(saved.inReplyTo, originalMessageID, "draft should thread via In-Reply-To")
    }

    private func cleanUpAfterVerificationError(
        provider: IMAPMailProvider,
        credentials: MailAccountCredentials,
        marker: String
    ) async {
        do {
            try await cleanUpTestDraft(provider: provider, credentials: credentials, marker: marker)
        } catch {
            XCTFail("Failed to clean up att.net live draft after verification error: \(error.localizedDescription)")
        }
    }

    /// Moves the test draft to Trash so the real Drafts folder is left clean, then
    /// asserts it is gone. (Permanent expunge is out of scope for the provider;
    /// Trash keeps it recoverable, matching item 42's non-destructive delete.)
    private func cleanUpTestDraft(
        provider: IMAPMailProvider,
        credentials: MailAccountCredentials,
        marker: String
    ) async throws {
        _ = try await provider.applyBulkCleanup(
            credentials,
            mailbox: .drafts,
            criteria: MailSearchCriteria(subject: marker),
            action: .moveToTrash,
            selectionCap: 50,
            onProgress: nil
        )

        let after = try await provider.searchMessages(
            credentials,
            mailbox: .drafts,
            criteria: MailSearchCriteria(subject: marker),
            offset: 0,
            limit: 10
        )
        XCTAssertFalse(
            after.messages.contains { $0.subject.contains(marker) },
            "the test draft should be removed from Drafts after cleanup"
        )
    }
}
