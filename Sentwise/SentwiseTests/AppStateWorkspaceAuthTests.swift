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
        await appState.registerGoogleOAuthInterest(isHuntMode: false)
        XCTAssertEqual(client.callCount, 0, "signed-out clicks never reach the network")
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
