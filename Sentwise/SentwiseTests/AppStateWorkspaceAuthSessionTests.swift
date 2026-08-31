import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateWorkspaceAuthSessionTests: XCTestCase {

    func testRegistrationPersistsCapturedStableAccountAfterSignOutFollowingSessionAcquisition() async throws {
        let client = SuspendingGoogleOAuthInterestClient()
        let store = InMemoryGoogleOAuthInterestStore()
        let secrets = InMemorySecretStore(seed: [.managedSessionID: "sess-a"])
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            googleOAuthInterestClient: client
        )
        appState.googleOAuthInterestStore = store
        appState.isManagedSignedIn = true
        appState.managedAccountEmail = "marcus@example.com"
        appState.managedAccountID = "acct-a"
        appState.refreshGoogleOAuthInterestState()
        let capturedStableKey = appState.currentManagedUsageAccountKey
        let capturedSessionKey = ManagedUsageAccountKey.make(from: "clerk-session:sess-a")

        let registration = Task {
            await appState.registerGoogleOAuthInterest(isHuntMode: false)
        }
        await fulfillment(of: [client.didStart], timeout: 1)

        try secrets.remove(.managedSessionID)
        appState.isManagedSignedIn = false
        appState.managedAccountEmail = ""
        appState.managedAccountID = ""

        client.succeed(accountKey: capturedSessionKey)
        await registration.value

        XCTAssertTrue(store.isRegistered(accountKey: capturedSessionKey))
        XCTAssertTrue(store.isRegistered(accountKey: capturedStableKey))
        XCTAssertFalse(appState.googleOAuthInterestRegistered)
    }

    func testRegistrationPreservesBackfilledStableKeyAfterSignOut() async throws {
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
            llm: ManagedStatusLLMProvider(status: ManagedAccountStatus(userID: "user_123")),
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

        await appState.refreshManagedQuota()
        let stableKey = appState.currentManagedUsageAccountKey
        await appState.signOutManaged()

        client.succeed()
        await registration.value

        XCTAssertTrue(store.isRegistered(accountKey: legacyKey))
        XCTAssertTrue(store.isRegistered(accountKey: stableKey))
        XCTAssertFalse(appState.googleOAuthInterestRegistered)
    }
}
