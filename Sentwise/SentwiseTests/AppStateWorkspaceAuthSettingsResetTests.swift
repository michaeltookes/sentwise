import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateWorkspaceAuthSettingsResetTests: XCTestCase {

    private func makeAppState(interestClient: GoogleOAuthInterestRegistering) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            googleOAuthInterestClient: interestClient
        )
    }

    func testSettingsResetSuppressesStaleInterestRegistrationError() async {
        let client = SuspendingGoogleOAuthInterestClient()
        let appState = makeAppState(interestClient: client)
        appState.googleOAuthInterestStore = InMemoryGoogleOAuthInterestStore()
        appState.isManagedSignedIn = true
        appState.managedAccountID = "acct-1"
        appState.refreshGoogleOAuthInterestState()

        let registration = Task {
            await appState.registerGoogleOAuthInterest(isHuntMode: false)
        }
        await fulfillment(of: [client.didStart], timeout: 1)

        appState.resetTransientSettingsMessages()
        client.fail(with: LLMError.transport("offline"))
        await registration.value

        XCTAssertNil(appState.googleOAuthInterestError)
        XCTAssertNil(appState.managedError)
        XCTAssertFalse(appState.isRegisteringGoogleOAuthInterest)
        XCTAssertTrue(appState.canOfferGoogleOAuthInterest)
    }
}
