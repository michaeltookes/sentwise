import SentwiseMail
import XCTest
@testable import Sentwise

/// Follow-ups to Google watcher recovery (item 6i (c), (d)): a body-fetch
/// auth failure during drafting requests Google recovery like a poll failure
/// does, and a background Google mailbox whose grant expired can be signed in
/// again from its own row.
extension GoogleSignInTests {
    private func watchingGoogleHarness(idEmail: String = "me@gmail.com") async throws -> Harness {
        let harness = makeHarness(idEmail: idEmail)
        try seedToken(harness.store)
        let connected = await harness.appState.testConnection(with: GoogleMailCredential.credentials(email: "me@gmail.com"))
        XCTAssertTrue(connected)
        harness.appState.llmProviderKind = .anthropic
        harness.appState.isLLMConnected = true
        harness.appState.startWatching()
        XCTAssertEqual(harness.appState.watchStatus, .watching)
        return harness
    }

    /// The error `makePendingDraft`'s body fetch surfaces when Gmail rejects the grant.
    private var bodyFetchAuthFailure: MailError {
        .authenticationFailed(GoogleMailCredential.reauthorizationDetail)
    }

    // MARK: - (d) Draft-path auth failures

    func testBodyFetchAuthFailureResumesWatcherAfterReauthorization() async throws {
        let harness = try await watchingGoogleHarness()
        let app = harness.appState
        defer { app.stopWatching() }

        app.handleWatcherDraftError(bodyFetchAuthFailure, credentials: app.mailCredentials, draftProvider: .anthropic)
        XCTAssertEqual(app.watchStatus, .paused)
        XCTAssertTrue(app.resumeWatchingAfterGoogleReauth)
        XCTAssertNotNil(app.watchError)

        let connected = await app.connectWithGoogle(loginHint: app.mailEmail, requireHintMatch: true)

        XCTAssertTrue(connected)
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertNil(app.watchError)
        XCTAssertFalse(app.resumeWatchingAfterGoogleReauth)
    }

    func testAIProviderAuthFailureIsNotResumedByGoogleReauthorization() async throws {
        let cases: [(LLMError, LLMProviderKind)] = [(.missingAPIKey, .anthropic), (.managedNotSignedIn, .managed)]
        for (error, provider) in cases {
            let harness = try await watchingGoogleHarness()
            let app = harness.appState

            app.handleWatcherDraftError(error, credentials: app.mailCredentials, draftProvider: provider)
            XCTAssertEqual(app.watchStatus, .paused)
            XCTAssertFalse(app.resumeWatchingAfterGoogleReauth, "\(error)")
            XCTAssertEqual(app.resumeWatchingAfterManagedReauth, provider == .managed)

            let connected = await app.connectWithGoogle(loginHint: app.mailEmail, requireHintMatch: true)

            XCTAssertTrue(connected)
            XCTAssertEqual(app.watchStatus, .paused, "a mailbox sign-in doesn't fix the AI provider (\(error))")
            app.stopWatching()
        }
    }

    func testAppPasswordBodyFetchAuthFailureDoesNotRequestGoogleRecovery() async throws {
        let harness = try await watchingGoogleHarness()
        let app = harness.appState
        defer { app.stopWatching() }
        let credentials = MailAccountCredentials(email: "me@gmail.com", appPassword: "pw", host: "imap.gmail.com", port: 993)

        app.handleWatcherDraftError(bodyFetchAuthFailure, credentials: credentials, draftProvider: .anthropic)

        XCTAssertEqual(app.watchStatus, .paused)
        XCTAssertFalse(app.resumeWatchingAfterGoogleReauth)
    }

    func testBackgroundBodyFetchAuthFailureRequestsRecoveryForThatAccount() async throws {
        let harness = try await watchingGoogleHarness()
        let app = harness.appState
        defer { app.stopWatching(); app.stopAllBackgroundWatchers() }
        let other = backgroundGoogleAccount(harness, email: "other@gmail.com")

        app.handleWatcherDraftError(
            bodyFetchAuthFailure, credentials: other.credentials, draftProvider: .anthropic, account: other
        )

        XCTAssertEqual(other.watchStatus, .paused)
        XCTAssertTrue(other.resumeWatchingAfterGoogleReauth)
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertFalse(app.resumeWatchingAfterGoogleReauth)
    }

    // MARK: - (c) Reconnecting a background Google mailbox

    private func backgroundGoogleAccount(_ harness: Harness, email: String) -> ConnectedMailAccount {
        try? seedToken(harness.store, email: email)
        try? harness.secrets.set(GoogleMailCredential.marker, for: .mailAppPassword(email: email))
        harness.appState.upsertSavedAccount(email: email, host: GoogleMailCredential.imapHost, port: GoogleMailCredential.imapPort)
        let account = ConnectedMailAccount(
            email: email, host: GoogleMailCredential.imapHost, port: GoogleMailCredential.imapPort,
            appPassword: GoogleMailCredential.marker
        )
        account.watchStatus = .watching
        harness.appState.backgroundConnectedAccounts.append(account)
        return account
    }

    private func savedAccount(_ app: AppState, _ email: String) throws -> SavedMailAccount {
        try XCTUnwrap(app.savedAccounts.first { $0.id == SavedMailAccount.normalizedEmail(email) })
    }

    func testExpiredBackgroundGoogleMailboxOffersReconnectAndRecovers() async throws {
        let harness = try await watchingGoogleHarness(idEmail: "other@gmail.com")
        let app = harness.appState
        defer { app.stopWatching(); app.stopAllBackgroundWatchers() }
        let other = backgroundGoogleAccount(harness, email: "other@gmail.com")
        let saved = try savedAccount(app, "other@gmail.com")
        XCTAssertFalse(app.savedAccountNeedsGoogleReauth(saved), "a healthy mailbox needs no reconnect")

        app.handlePollFetchFailure(bodyFetchAuthFailure, account: other)
        XCTAssertTrue(app.savedAccountNeedsGoogleReauth(saved))
        XCTAssertFalse(app.savedAccountNeedsGoogleReauth(try savedAccount(app, "me@gmail.com")), "the focused row has its own button")

        // What the row's "Sign in with Google again" runs.
        let connected = await app.connectWithGoogle(loginHint: saved.email, requireHintMatch: true, messageSurface: .settings)

        XCTAssertTrue(connected)
        XCTAssertEqual(app.mailEmail, "other@gmail.com")
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertNil(app.watchError)
        XCTAssertFalse(app.savedAccountNeedsGoogleReauth(saved))
        XCTAssertEqual(app.backgroundConnectedAccount(email: "me@gmail.com")?.watchStatus, .watching)
    }

    func testReconnectIsNotOfferedForManualPausesOrAppPasswordMailboxes() async throws {
        let harness = try await watchingGoogleHarness()
        let app = harness.appState
        defer { app.stopWatching(); app.stopAllBackgroundWatchers() }
        let google = backgroundGoogleAccount(harness, email: "other@gmail.com")
        app.handlePollFetchFailure(bodyFetchAuthFailure, account: google)
        app.pauseWatching(account: google)
        XCTAssertFalse(app.savedAccountNeedsGoogleReauth(try savedAccount(app, "other@gmail.com")))

        try harness.secrets.set("pw", for: .mailAppPassword(email: "third@yahoo.com"))
        app.upsertSavedAccount(email: "third@yahoo.com", host: "imap.mail.yahoo.com", port: 993)
        let appPassword = ConnectedMailAccount(email: "third@yahoo.com", host: "imap.mail.yahoo.com", port: 993, appPassword: "pw")
        appPassword.watchStatus = .watching
        app.backgroundConnectedAccounts.append(appPassword)
        app.handlePollFetchFailure(MailError.authenticationFailed("bad password"), account: appPassword)
        XCTAssertFalse(app.savedAccountNeedsGoogleReauth(try savedAccount(app, "third@yahoo.com")))
    }

    func testReconnectIsNotOfferedWithoutABundledClient() async throws {
        let harness = try await watchingGoogleHarness()
        let app = harness.appState
        defer { app.stopWatching(); app.stopAllBackgroundWatchers() }
        let other = backgroundGoogleAccount(harness, email: "other@gmail.com")
        app.handlePollFetchFailure(bodyFetchAuthFailure, account: other)
        app.googleMailAuth.install(nil)

        XCTAssertFalse(app.savedAccountNeedsGoogleReauth(try savedAccount(app, "other@gmail.com")))
    }
}
