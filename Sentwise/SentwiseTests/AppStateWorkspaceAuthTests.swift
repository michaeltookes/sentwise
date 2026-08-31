import SentwiseMail
import XCTest
@testable import Sentwise

/// AppState-level tests for the Workspace app-password guidance and the "Sign in
/// with Google" interest capture (item 75): a failed IMAP connect classifies and
/// records a PII-free activity entry, and the interest button's state machine
/// (hidden signed-out, confirm persisted, hunt no-op) behaves.
@MainActor
final class AppStateWorkspaceAuthTests: XCTestCase {

    private let workspaceInvalidCredentials = "[AUTHENTICATIONFAILED] Invalid credentials (Failure)"

    private func makeAppState(
        provider: MailProvider,
        interestClient: GoogleOAuthInterestRegistering = RecordingGoogleOAuthInterestClient()
    ) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore(),
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(())),
            googleOAuthInterestClient: interestClient
        )
    }

    private func workspaceCredentials(email: String = "marcus@acme.com") -> MailAccountCredentials {
        MailAccountCredentials(email: email, appPassword: "abcd efgh ijkl mnop", host: "imap.gmail.com", port: 993)
    }

    // MARK: - Classification + guidance on a failed connect

    func testWorkspaceAppPasswordRejectionSurfacesGuidance() async {
        let provider = FakeAppMailProvider(result: .failure(.authenticationFailed(workspaceInvalidCredentials)))
        let appState = makeAppState(provider: provider)

        await appState.testConnection(with: workspaceCredentials())

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertEqual(appState.workspaceAuthFailure, .appPasswordRejectedWorkspace)
        XCTAssertTrue(appState.workspaceAuthIsCustomDomain)
        XCTAssertNotNil(appState.workspaceAuthGuidance)
        XCTAssertNotNil(appState.connectionError, "the generic error is still shown alongside guidance")
    }

    func testConsumerGmailInvalidCredentialsShowsNoWorkspaceGuidance() async {
        let provider = FakeAppMailProvider(result: .failure(.authenticationFailed(workspaceInvalidCredentials)))
        let appState = makeAppState(provider: provider)

        await appState.testConnection(with: workspaceCredentials(email: "me@gmail.com"))

        XCTAssertEqual(appState.workspaceAuthFailure, .none)
        XCTAssertNil(appState.workspaceAuthGuidance)
        XCTAssertFalse(appState.activityEvents.contains { $0.kind == .workspaceAuthGuidance })
    }

    func testGuidanceIsClearedOnASubsequentSuccessfulConnect() async {
        // A prior failure left guidance on screen; a successful connect must clear
        // it (testConnection resets the guidance before verifying).
        let appState = makeAppState(provider: FakeAppMailProvider(result: .success(())))
        appState.workspaceAuthFailure = .imapDisabled
        appState.workspaceAuthIsCustomDomain = true
        XCTAssertNotNil(appState.workspaceAuthGuidance)

        await appState.testConnection(with: workspaceCredentials())

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(appState.workspaceAuthFailure, .none)
        XCTAssertNil(appState.workspaceAuthGuidance)
    }

    func testDisconnectClearsGuidance() async {
        let appState = makeAppState(provider: FakeAppMailProvider(result: .success(())))
        await appState.testConnection(with: workspaceCredentials())
        appState.workspaceAuthFailure = .webLoginRequired
        appState.disconnectMail()
        XCTAssertEqual(appState.workspaceAuthFailure, .none)
    }

    // MARK: - Activity entry has no PII

    func testWorkspaceGuidanceActivityEntryRecordsClassNameOnlyNoPII() async {
        let provider = FakeAppMailProvider(result: .failure(.authenticationFailed(workspaceInvalidCredentials)))
        let appState = makeAppState(provider: provider)

        await appState.testConnection(with: workspaceCredentials(email: "marcus@acme.com"))

        let events = appState.activityEvents.filter { $0.kind == .workspaceAuthGuidance }
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event.detail, "appPasswordRejectedWorkspace")
        // No PII: never the email, sender, subject, mailbox, host, or credentials.
        XCTAssertNil(event.account)
        XCTAssertNil(event.sender)
        XCTAssertNil(event.subject)
        XCTAssertNil(event.mailbox)
        XCTAssertNil(event.sourceMailHost)
        XCTAssertNil(event.messageUID)
        XCTAssertFalse(event.detail?.contains("acme.com") ?? false)
        XCTAssertFalse(event.detail?.contains("abcd") ?? false)
    }

    // MARK: - Interest capture state machine

    func testInterestButtonHiddenWhenSignedOut() async {
        let client = RecordingGoogleOAuthInterestClient()
        let appState = makeAppState(provider: FakeAppMailProvider(result: .success(())), interestClient: client)
        appState.isManagedSignedIn = false

        XCTAssertFalse(appState.canOfferGoogleOAuthInterest)
        XCTAssertTrue(appState.canOfferGoogleOAuthInterestSignIn)
        await appState.registerGoogleOAuthInterest(isHuntMode: false)
        XCTAssertEqual(client.callCount, 0, "signed-out clicks never reach the network")
    }

    func testWorkspaceGuidanceCanOfferManagedSignInBeforeMailboxConnects() {
        let appState = makeAppState(provider: FakeAppMailProvider(result: .success(())))
        appState.workspaceAuthFailure = .appPasswordRejectedWorkspace
        appState.workspaceAuthIsCustomDomain = true
        appState.isManagedSignedIn = false

        XCTAssertNotNil(appState.workspaceAuthGuidance)
        XCTAssertTrue(appState.canOfferGoogleOAuthInterestSignIn)
        XCTAssertFalse(appState.canOfferGoogleOAuthInterest)
    }

    func testRegisteringInterestPostsOnceAndPersistsConfirmation() async {
        let client = RecordingGoogleOAuthInterestClient()
        let store = InMemoryGoogleOAuthInterestStore()
        let appState = makeAppState(provider: FakeAppMailProvider(result: .success(())), interestClient: client)
        appState.googleOAuthInterestStore = store
        appState.isManagedSignedIn = true
        appState.managedAccountID = "acct-1"
        appState.refreshGoogleOAuthInterestState()
        XCTAssertTrue(appState.canOfferGoogleOAuthInterest)

        await appState.registerGoogleOAuthInterest(isHuntMode: false)

        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(client.lastTopic, "google-oauth")
        XCTAssertTrue(appState.googleOAuthInterestRegistered)
        XCTAssertFalse(appState.canOfferGoogleOAuthInterest, "the button isn't re-offered after a click")
        XCTAssertNil(appState.googleOAuthInterestError)

        // A second click no-ops (already registered), and the choice persists so a
        // relaunch reading the same store doesn't re-offer.
        await appState.registerGoogleOAuthInterest(isHuntMode: false)
        XCTAssertEqual(client.callCount, 1)
        XCTAssertTrue(store.isRegistered(accountKey: ManagedUsageAccountKey.make(from: "acct-1")))
    }

    func testRegisteringInterestUsesFallbackSessionKeyWhenStableAccountIDIsMissing() async {
        let client = RecordingGoogleOAuthInterestClient()
        let store = InMemoryGoogleOAuthInterestStore()
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_legacy",
            .managedSessionID: "sess_legacy"
        ])
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            googleOAuthInterestClient: client
        )
        appState.googleOAuthInterestStore = store
        appState.isManagedSignedIn = true
        appState.managedAccountEmail = "your Google account"
        appState.managedAccountID = ""
        appState.refreshGoogleOAuthInterestState()

        await appState.registerGoogleOAuthInterest(isHuntMode: false)

        XCTAssertEqual(client.callCount, 1)
        XCTAssertTrue(store.isRegistered(
            accountKey: ManagedUsageAccountKey.make(from: "clerk-session:sess_legacy")
        ))
        XCTAssertFalse(store.isRegistered(accountKey: ManagedUsageAccountKey.unknown))
    }

    func testRegisteringInterestMarksCapturedAccountIfAccountChangesWhileRequestIsSuspended() async {
        let client = SuspendingGoogleOAuthInterestClient()
        let store = InMemoryGoogleOAuthInterestStore()
        let appState = makeAppState(provider: FakeAppMailProvider(result: .success(())), interestClient: client)
        appState.googleOAuthInterestStore = store
        appState.isManagedSignedIn = true
        appState.managedAccountEmail = "marcus@example.com"
        appState.managedAccountID = "acct-1"
        appState.refreshGoogleOAuthInterestState()
        let oldKey = appState.currentManagedUsageAccountKey

        let registration = Task {
            await appState.registerGoogleOAuthInterest(isHuntMode: false)
        }
        await fulfillment(of: [client.didStart], timeout: 1)
        XCTAssertTrue(appState.isRegisteringGoogleOAuthInterest)

        appState.managedAccountEmail = "priya@example.com"
        appState.managedAccountID = "acct-2"
        appState.refreshGoogleOAuthInterestState()
        let newKey = appState.currentManagedUsageAccountKey

        client.succeed()
        await registration.value

        XCTAssertTrue(store.isRegistered(accountKey: oldKey))
        XCTAssertFalse(store.isRegistered(accountKey: newKey))
        XCTAssertFalse(appState.googleOAuthInterestRegistered)
    }

    func testRegisteringInterestSurvivesStableIDBackfillWhileRequestIsSuspended() async {
        let client = SuspendingGoogleOAuthInterestClient()
        let store = InMemoryGoogleOAuthInterestStore()
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_legacy",
            .managedSessionID: "sess_legacy"
        ])
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            googleOAuthInterestClient: client
        )
        appState.googleOAuthInterestStore = store
        appState.isManagedSignedIn = true
        appState.managedAccountEmail = "your Google account"
        appState.managedAccountID = ""
        appState.refreshGoogleOAuthInterestState()
        let legacyKey = appState.currentManagedUsageAccountKey

        let registration = Task {
            await appState.registerGoogleOAuthInterest(isHuntMode: false)
        }
        await fulfillment(of: [client.didStart], timeout: 1)

        appState.managedAccountID = "clerk-user:user_123"
        let stableKey = appState.currentManagedUsageAccountKey
        appState.managedQuotaAccountKeyAliases[legacyKey] = stableKey

        client.succeed()
        await registration.value

        XCTAssertTrue(store.isRegistered(accountKey: stableKey))
        XCTAssertFalse(store.isRegistered(accountKey: legacyKey))
        XCTAssertTrue(appState.googleOAuthInterestRegistered)
    }

    func testUnauthorizedInterestRegistrationReconcilesSignedOutState() async {
        let client = RecordingGoogleOAuthInterestClient(error: LLMError.managedNotSignedIn)
        let appState = makeAppState(provider: FakeAppMailProvider(result: .success(())), interestClient: client)
        appState.googleOAuthInterestStore = InMemoryGoogleOAuthInterestStore()
        appState.isManagedSignedIn = true
        appState.managedAccountEmail = "marcus@example.com"
        appState.managedAccountID = "acct-1"
        appState.refreshGoogleOAuthInterestState()

        await appState.registerGoogleOAuthInterest(isHuntMode: false)

        XCTAssertEqual(client.callCount, 1)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.canOfferGoogleOAuthInterest)
        XCTAssertTrue(appState.canOfferGoogleOAuthInterestSignIn)
        XCTAssertNotNil(appState.managedError)
    }

    func testInterestErrorLeavesButtonOffered() async {
        let client = RecordingGoogleOAuthInterestClient(error: LLMError.transport("offline"))
        let appState = makeAppState(provider: FakeAppMailProvider(result: .success(())), interestClient: client)
        appState.googleOAuthInterestStore = InMemoryGoogleOAuthInterestStore()
        appState.isManagedSignedIn = true
        appState.managedAccountID = "acct-1"
        appState.refreshGoogleOAuthInterestState()

        await appState.registerGoogleOAuthInterest(isHuntMode: false)

        XCTAssertFalse(appState.googleOAuthInterestRegistered)
        XCTAssertNotNil(appState.googleOAuthInterestError)
        XCTAssertTrue(appState.canOfferGoogleOAuthInterest, "a failed attempt can be retried")
    }

    func testHuntModeInterestIsANoOp() async {
        let client = RecordingGoogleOAuthInterestClient()
        let appState = makeAppState(provider: FakeAppMailProvider(result: .success(())), interestClient: client)
        appState.googleOAuthInterestStore = InMemoryGoogleOAuthInterestStore()
        appState.isManagedSignedIn = true
        appState.managedAccountID = "acct-1"
        appState.refreshGoogleOAuthInterestState()

        await appState.registerGoogleOAuthInterest(isHuntMode: true)

        XCTAssertEqual(client.callCount, 0, "hunt mode never touches the network")
        XCTAssertFalse(appState.googleOAuthInterestRegistered)
    }

    func testRefreshReflectsPriorRegistrationForThisAccount() {
        let store = InMemoryGoogleOAuthInterestStore()
        store.markRegistered(accountKey: ManagedUsageAccountKey.make(from: "acct-1"))
        let appState = makeAppState(provider: FakeAppMailProvider(result: .success(())))
        appState.googleOAuthInterestStore = store
        appState.isManagedSignedIn = true
        appState.managedAccountID = "acct-1"

        appState.refreshGoogleOAuthInterestState()

        XCTAssertTrue(appState.googleOAuthInterestRegistered)
        XCTAssertFalse(appState.canOfferGoogleOAuthInterest)
    }
}

/// A recording interest client that suspends until the test completes it, so the
/// AppState race around account switches can be exercised deterministically.
final class SuspendingGoogleOAuthInterestClient: GoogleOAuthInterestRegistering, @unchecked Sendable {
    let didStart = XCTestExpectation(description: "interest registration started")

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var _callCount = 0
    private var _lastTopic: String?

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var lastTopic: String? { lock.lock(); defer { lock.unlock() }; return _lastTopic }

    func registerInterest(topic: String) async throws {
        await withCheckedContinuation { continuation in
            lock.lock()
            _callCount += 1
            _lastTopic = topic
            self.continuation = continuation
            lock.unlock()
            didStart.fulfill()
        }
    }

    func succeed() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
