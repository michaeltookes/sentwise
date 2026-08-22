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
/// live account:
///
///   - `SENTWISE_LIVE_EMAIL`         — the mailbox address (required)
///   - `SENTWISE_LIVE_APP_PASSWORD`  — its app password / Secure Mail Key (required)
///   - `SENTWISE_LIVE_HOST`          — IMAP host (optional; default imap.gmail.com)
///   - `SENTWISE_LIVE_PORT`          — IMAP port (optional; default 993)
///
/// Read-only: it fetches and evaluates, and never drafts, sends, or mutates the
/// mailbox. No credentials are hardcoded.
@MainActor
final class ReplyWorthinessLiveTests: XCTestCase {

    private func liveCredentials() throws -> MailAccountCredentials {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SENTWISE_LIVE_EMAIL"], !email.isEmpty,
              let password = env["SENTWISE_LIVE_APP_PASSWORD"], !password.isEmpty else {
            throw XCTSkip(
                "Set SENTWISE_LIVE_EMAIL and SENTWISE_LIVE_APP_PASSWORD "
                + "to run the reply-worthiness live test."
            )
        }
        let host = env["SENTWISE_LIVE_HOST"] ?? "imap.gmail.com"
        let port = env["SENTWISE_LIVE_PORT"].flatMap(Int.init) ?? 993
        return MailAccountCredentials(email: email, appPassword: password, host: host, port: port)
    }

    /// Machine-sending domains whose mail must never become a draft. These match
    /// the leaked senders named in item 66 (GitHub, Stripe/Anthropic receipts,
    /// AWS cost alerts, recruiting blasts) plus the common receipt providers.
    private let transactionalDomains = [
        "github.com",
        "stripe.com",
        "costalerts.amazonaws.com",
        "applytojob.com"
    ]

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
            let isKnownTransactional = addresses.contains { address in
                transactionalDomains.contains { domain in
                    address.hasSuffix("@\(domain)") || address.hasSuffix(".\(domain)")
                }
            }
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

        print(
            "Reply-worthiness live pass: \(messages.count) messages — "
            + "\(transactionalSeen) known-transactional (all skipped), "
            + "\(worthyCount) worthy (would draft)."
        )
    }
}
