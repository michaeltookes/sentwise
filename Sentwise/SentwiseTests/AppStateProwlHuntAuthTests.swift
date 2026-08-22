import XCTest
@testable import Sentwise

@MainActor
/// The hunt-mode deterministic offline fakes for the item-59 sign-in and provider
/// flows (item 70): they complete managed sign-in (email + Google) and OpenRouter
/// provisioning fully in memory — no network, no Clerk/OpenRouter/Anthropic call,
/// no browser. These exercise the exact `AppState` methods the sign-in hunts
/// drive, with `isHuntMode: true` injected (unit tests do not otherwise run in
/// hunt mode, so the default parameter resolves to `false` here — see
/// ProwlHuntRuntimeTests).
final class AppStateProwlHuntAuthTests: XCTestCase {

    private func makeAppState(
        secrets: InMemorySecretStore = InMemorySecretStore()
    ) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                llmProvider: "managed"
            )),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    func testHuntEmailSignInAdvancesToCodeStageThenConnects() async {
        let appState = makeAppState()
        XCTAssertFalse(appState.isManagedSignedIn)

        appState.managedEmailInput = "hunt.fixture@sentwise.invalid"
        await appState.startManagedSignIn(isHuntMode: true)

        XCTAssertEqual(appState.managedSignInStage, .codeSent)
        XCTAssertNil(appState.managedError)
        XCTAssertFalse(appState.isManagedSignedIn)

        appState.managedCodeInput = "000000"
        await appState.verifyManagedCode(isHuntMode: true)

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertEqual(appState.managedAccountEmail, "hunt.fixture@sentwise.invalid")
        XCTAssertEqual(appState.managedSignInStage, .idle)
        XCTAssertTrue(appState.isManagedProviderActive)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertNil(appState.managedError)
    }

    func testHuntEmailVerifyDoesNotDependOnCodeTextFieldCommit() async {
        let appState = makeAppState()
        appState.managedEmailInput = "hunt.fixture@sentwise.invalid"
        await appState.startManagedSignIn(isHuntMode: true)

        await appState.verifyManagedCode(isHuntMode: true)

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isManagedProviderActive)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertNil(appState.managedError)
    }

    func testHuntEmailSignInRejectsBlankEmailWithoutNetwork() async {
        let appState = makeAppState()
        appState.managedEmailInput = ""
        await appState.startManagedSignIn(isHuntMode: true)

        XCTAssertEqual(appState.managedSignInStage, .idle)
        XCTAssertNotNil(appState.managedError)
        XCTAssertFalse(appState.isManagedSignedIn)
    }

    func testHuntGoogleSignInShowsWaitingPanelWithoutBrowserThenCompletes() async {
        let appState = makeAppState()
        var openedURLs: [URL] = []
        await appState.startManagedGoogleSignIn(openURL: { openedURLs.append($0) }, isHuntMode: true)

        XCTAssertEqual(appState.managedSignInStage, .awaitingBrowser)
        XCTAssertTrue(openedURLs.isEmpty, "hunt mode must not open a real browser")
        XCTAssertFalse(appState.isManagedSignedIn)

        appState.completeManagedGoogleSignInForHunt(isHuntMode: true)

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertEqual(appState.managedAccountEmail, AppState.huntFixtureGoogleEmail)
        XCTAssertTrue(appState.isManagedProviderActive)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(appState.managedSignInStage, .idle)
    }

    func testHuntOpenRouterProvisioningActivatesFakeProviderOffline() {
        let appState = makeAppState()
        XCTAssertTrue(appState.isManagedProviderActive)

        appState.completeOpenRouterProvisioningForHunt(isHuntMode: true)

        XCTAssertEqual(appState.llmProviderKind, .openAICompatible)
        XCTAssertEqual(appState.llmBaseURL, OpenRouterKeyProvisioner.apiBaseURL)
        XCTAssertEqual(appState.llmModel, AppState.openRouterDefaultModel)
        XCTAssertEqual(appState.verifiedLLMModel, AppState.openRouterDefaultModel)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertTrue(appState.isBYOProviderActive)
        XCTAssertEqual(try? appState.secrets.value(for: .openRouterAPIKey), "hunt-openrouter-fixture-key")
    }

    func testCompletionFakesNoOpOutsideHuntMode() {
        // The completion fakes are strictly hunt-gated: called with isHuntMode:false
        // they change nothing, so the production callback paths are never affected.
        let appState = makeAppState()

        appState.completeManagedGoogleSignInForHunt(isHuntMode: false)
        XCTAssertFalse(appState.isManagedSignedIn)

        let providerBefore = appState.llmProviderKind
        appState.completeOpenRouterProvisioningForHunt(isHuntMode: false)
        XCTAssertEqual(appState.llmProviderKind, providerBefore)
        XCTAssertTrue(appState.isManagedProviderActive)
    }
}
