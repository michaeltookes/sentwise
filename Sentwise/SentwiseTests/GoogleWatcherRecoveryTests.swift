import SentwiseMail
import XCTest
@testable import Sentwise

extension GoogleSignInTests {
    private func connectedWatcherHarness(idEmail: String = "me@gmail.com") async throws -> Harness {
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

    private func pauseForGoogleFailure(_ app: AppState, account: ConnectedMailAccount? = nil) {
        app.handlePollFetchFailure(
            MailError.authenticationFailed(GoogleMailCredential.reauthorizationDetail), account: account
        )
        XCTAssertEqual(app.accountWatchStatus(account), .paused)
    }

    func testReauthorizationResumesAuthPausedWatcherAndClearsError() async throws {
        let harness = try await connectedWatcherHarness()
        let app = harness.appState
        defer { app.stopWatching() }
        pauseForGoogleFailure(app)
        XCTAssertTrue(app.resumeWatchingAfterGoogleReauth)
        XCTAssertNotNil(app.watchError)
        let other = ConnectedMailAccount(email: "other@gmail.com", host: "imap.gmail.com", port: 993, appPassword: "pw")
        other.watchStatus = .paused
        app.backgroundConnectedAccounts = [other]

        let connected = await app.connectWithGoogle(loginHint: app.mailEmail, requireHintMatch: true)

        XCTAssertTrue(connected)
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertNil(app.watchError)
        XCTAssertFalse(app.resumeWatchingAfterGoogleReauth)
        XCTAssertEqual(other.watchStatus, .paused, "Recovery must not start unrelated watchers")
    }

    func testReauthorizationPreservesManualPause() async throws {
        let harness = try await connectedWatcherHarness()
        let app = harness.appState
        app.pauseWatching()

        let connected = await app.connectWithGoogle(loginHint: app.mailEmail, requireHintMatch: true)

        XCTAssertTrue(connected)
        XCTAssertEqual(app.watchStatus, .paused)
        XCTAssertFalse(app.resumeWatchingAfterGoogleReauth)
    }

    func testManualPauseOrStopCancelsGoogleRecoveryIntent() async throws {
        for stop in [false, true] {
            let harness = try await connectedWatcherHarness()
            let app = harness.appState
            pauseForGoogleFailure(app)
            if stop { app.stopWatching() } else { app.pauseWatching() }

            let connected = await app.connectWithGoogle(loginHint: app.mailEmail, requireHintMatch: true)

            XCTAssertTrue(connected)
            XCTAssertEqual(app.watchStatus, stop ? .idle : .paused)
            XCTAssertFalse(app.resumeWatchingAfterGoogleReauth)
        }
    }

    func testFailedReauthorizationKeepsAuthPauseAndError() async throws {
        let harness = try await connectedWatcherHarness(idEmail: "wrong@gmail.com")
        let app = harness.appState
        pauseForGoogleFailure(app)
        let error = app.watchError

        let connected = await app.connectWithGoogle(loginHint: app.mailEmail, requireHintMatch: true)

        XCTAssertFalse(connected)
        XCTAssertEqual(app.watchStatus, .paused)
        XCTAssertEqual(app.watchError, error)
        XCTAssertTrue(app.resumeWatchingAfterGoogleReauth)
    }

    func testGoogleRecoveryWaitsForProviderReadiness() async throws {
        let harness = try await connectedWatcherHarness()
        let app = harness.appState
        defer { app.stopWatching() }
        pauseForGoogleFailure(app)
        app.isLLMConnected = false

        let connected = await app.connectWithGoogle(loginHint: app.mailEmail, requireHintMatch: true)

        XCTAssertTrue(connected)
        XCTAssertEqual(app.watchStatus, .paused)
        XCTAssertNil(app.watchError)
        XCTAssertFalse(app.resumeWatchingAfterGoogleReauth)
        XCTAssertTrue(app.resumeWatchingAfterManagedReauth)
        app.isLLMConnected = true
        app.resumeInboxWatchingAfterProviderRecoveryIfNeeded()
        XCTAssertEqual(app.watchStatus, .watching)
    }

    func testBackgroundAuthPauseFollowsAccountWhenReauthorized() async throws {
        let harness = try await connectedWatcherHarness(idEmail: "other@gmail.com")
        let app = harness.appState
        defer { app.stopWatching(); app.stopAllBackgroundWatchers() }
        // The original account is manually paused and must remain so after it
        // moves to the background while the other account is reauthorized.
        app.pauseWatching()
        try seedToken(harness.store, email: "other@gmail.com")
        try harness.secrets.set(GoogleMailCredential.marker, for: .mailAppPassword(email: "other@gmail.com"))
        let other = ConnectedMailAccount(
            email: "other@gmail.com", host: "imap.gmail.com", port: 993, appPassword: GoogleMailCredential.marker
        )
        other.watchStatus = .watching
        app.backgroundConnectedAccounts = [other]
        pauseForGoogleFailure(app, account: other)
        XCTAssertTrue(other.resumeWatchingAfterGoogleReauth)

        let connected = await app.connectWithGoogle(loginHint: other.email, requireHintMatch: true)

        XCTAssertTrue(connected)
        XCTAssertEqual(app.mailEmail, other.email)
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertNil(app.watchError)
        XCTAssertEqual(app.backgroundConnectedAccount(email: "me@gmail.com")?.watchStatus, .paused)
        XCTAssertFalse(app.backgroundConnectedAccount(email: "me@gmail.com")?.resumeWatchingAfterGoogleReauth ?? true)
    }

    func testAppPasswordAuthFailureDoesNotRequestGoogleRecovery() async throws {
        let harness = try await connectedWatcherHarness()
        harness.appState.mailAppPassword = "app-password"
        pauseForGoogleFailure(harness.appState)
        XCTAssertFalse(harness.appState.resumeWatchingAfterGoogleReauth)
    }
}
