import SentwiseMail
import XCTest
@testable import Sentwise

/// Live verification of the reply-worthiness gate (items 17/66) against a real
/// inbox, following the standing QA preference for a headless XCTest over a
/// manual click-through. It runs a fresh worthiness pass — the same
/// `replyWorthinessSkipReason` the watcher uses, including the live
/// `HEADER.FIELDS` fetch — over recent inbox mail and asserts that known
/// machine-sending senders produce a skip (zero drafts) while personal mail
/// stays worthy.
///
/// **Credential-gated:** SKIPS cleanly unless real IMAP credentials are supplied
/// through environment variables, so it never fails in CI or on a machine with no
/// live account. It reuses the shared Gmail live-test credentials (see
/// docs/live-verification.md):
///
///   - `SENTWISE_LIVE_GMAIL_EMAIL`         — the Gmail address (required)
///   - `SENTWISE_LIVE_GMAIL_APP_PASSWORD`  — its 16-character app password (required)
///   - `SENTWISE_LIVE_GMAIL_HOST`          — IMAP host (optional; default imap.gmail.com)
///   - `SENTWISE_LIVE_GMAIL_PORT`          — IMAP port (optional; default 993)
///
/// Read-only: it fetches and evaluates, and never drafts, sends, or mutates the
/// mailbox. No credentials are hardcoded.
@MainActor
final class ReplyWorthinessLiveTests: XCTestCase {

    private func liveCredentials() throws -> MailAccountCredentials {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SENTWISE_LIVE_GMAIL_EMAIL"], !email.isEmpty,
              let password = env["SENTWISE_LIVE_GMAIL_APP_PASSWORD"], !password.isEmpty else {
            throw XCTSkip(
                "Set SENTWISE_LIVE_GMAIL_EMAIL and SENTWISE_LIVE_GMAIL_APP_PASSWORD "
                + "to run the reply-worthiness live test."
            )
        }
        let host = env["SENTWISE_LIVE_GMAIL_HOST"] ?? "imap.gmail.com"
        let port = env["SENTWISE_LIVE_GMAIL_PORT"].flatMap(Int.init) ?? 993
        return MailAccountCredentials(email: email, appPassword: password, host: host, port: port)
    }

    /// Sender-only production signals whose mail must never become a draft.
    /// Reusing `ReplyWorthiness.evaluate` keeps this live-test predicate aligned
    /// with the conservative domain/local-part matching the watcher actually uses.
    private func isProductionKnownMachineSender(from: String?, replyTo: String?) -> Bool {
        let verdict = ReplyWorthiness.evaluate(
            ReplyWorthinessSignals(fromEmail: from, replyToEmail: replyTo)
        )
        switch verdict.skipReason {
        case .noReplySender, .automatedNotification:
            return true
        case .bulkOrListMail, .calendarInvite, .senderBlocklisted, .notReplyWorthyPerModel, nil:
            return false
        }
    }

    func testProductionKnownMachineSenderPredicateStaysConservative() {
        XCTAssertTrue(isProductionKnownMachineSender(from: "notifications@github.com", replyTo: nil))
        XCTAssertTrue(isProductionKnownMachineSender(from: "invoice+statements@stripe.com", replyTo: nil))
        XCTAssertTrue(isProductionKnownMachineSender(from: "anything@costalerts.amazonaws.com", replyTo: nil))

        XCTAssertFalse(isProductionKnownMachineSender(from: "recruiter@github.com", replyTo: nil))
        XCTAssertFalse(isProductionKnownMachineSender(from: "support@stripe.com", replyTo: nil))
        XCTAssertFalse(isProductionKnownMachineSender(from: "orders@smallshop.example", replyTo: nil))
        XCTAssertFalse(
            isProductionKnownMachineSender(
                from: "notifications@ats.example",
                replyTo: "recruiter@company.example"
            )
        )
    }

    func testKnownTransactionalSendersProduceNoDraftsOverLiveInbox() async throws {
        let credentials = try liveCredentials()
        let provider = IMAPMailProvider()

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

        let messages = try await provider.fetchRecentMessages(credentials, mailbox: .inbox, limit: 60)

        var transactionalSeen = 0
        var worthyCount = 0
        for message in messages {
            // Hoisted to a `let` before asserting — CI's Swift 6.1 forbids
            // `XCTAssert…(await …)`.
            let reason = await app.replyWorthinessSkipReason(
                message,
                credentials: credentials,
                mailbox: .inbox
            )
            let addresses = [message.from?.email, message.replyTo?.email]
                .compactMap { $0?.lowercased() }
            let isKnownTransactional = isProductionKnownMachineSender(
                from: message.from?.email,
                replyTo: message.replyTo?.email
            )
            if isKnownTransactional {
                transactionalSeen += 1
                XCTAssertNotNil(
                    reason,
                    "known-transactional sender \(addresses) should be skipped, not drafted"
                )
            } else if reason == nil {
                worthyCount += 1
            }
        }

        guard transactionalSeen > 0 else {
            throw XCTSkip("No known transactional sender found in the latest \(messages.count) inbox messages.")
        }
        XCTAssertGreaterThan(
            worthyCount,
            0,
            "Expected at least one recent message to remain worthy; this live pass did not exercise drafting eligibility."
        )
        print(
            "Reply-worthiness live pass: \(messages.count) messages — "
            + "\(transactionalSeen) known-transactional (all skipped), "
            + "\(worthyCount) worthy (would draft)."
        )
    }
}
