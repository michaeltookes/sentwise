import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class WorkspaceAuthInterestConcurrencyTests: XCTestCase {

    func testDuplicateInterestRegistrationIsIgnoredWhileFirstRequestIsInFlight() async {
        let client = SuspendingGoogleOAuthInterestClient()
        let store = InMemoryGoogleOAuthInterestStore()
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            googleOAuthInterestClient: client
        )
        appState.googleOAuthInterestStore = store
        appState.isManagedSignedIn = true
        appState.managedAccountID = "acct-1"
        appState.refreshGoogleOAuthInterestState()

        let firstRegistration = Task {
            await appState.registerGoogleOAuthInterest(isHuntMode: false)
        }
        await fulfillment(of: [client.didStart], timeout: 1)

        XCTAssertFalse(appState.canOfferGoogleOAuthInterest)

        await appState.registerGoogleOAuthInterest(isHuntMode: false)
        XCTAssertEqual(client.callCount, 1)

        client.succeed()
        await firstRegistration.value

        XCTAssertTrue(appState.googleOAuthInterestRegistered)
        XCTAssertTrue(store.isRegistered(accountKey: ManagedUsageAccountKey.make(from: "acct-1")))
    }
}
