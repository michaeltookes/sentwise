import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateProviderRecoveryTests: XCTestCase {

    private func makeAppState(
        provider: String = "managed",
        secrets: SecretStore = InMemorySecretStore(),
        llm: LLMProviding = FakeLLMProvider(result: .success(()))
    ) -> AppState {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: provider
        ))
        return AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm
        )
    }

    func testSuccessfulBYOConnectionResumesWatcherPausedByManagedLicenseGate() async {
        let tester = FakeLLMProvider(result: .success(()))
        let appState = makeAppState(llm: tester)
        prepareWatcherPausedByManagedLicenseGate(appState)
        appState.selectLLMProvider(.anthropic)
        appState.llmAPIKey = "sk-live"

        await appState.testLLMConnection()

        XCTAssertEqual(appState.watchStatus, .watching)
        XCTAssertFalse(appState.resumeWatchingAfterManagedReauth)
        appState.stopWatching()
    }

    func testStoredOpenRouterSelectionResumesWatcherPausedByManagedFallback() {
        let secrets = InMemorySecretStore(seed: [
            .openRouterAPIKey: "sk-or-existing"
        ])
        let appState = makeAppState(secrets: secrets)
        prepareWatcherPausedByManagedLicenseGate(appState)

        appState.selectLLMProvider(.openAICompatible)

        XCTAssertEqual(appState.watchStatus, .watching)
        XCTAssertFalse(appState.resumeWatchingAfterManagedReauth)
        appState.stopWatching()
    }

    private func prepareWatcherPausedByManagedLicenseGate(_ appState: AppState) {
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "app-pw"
        appState.isAccountConnected = true
        appState.watchStatus = .paused
        appState.resumeWatchingAfterManagedReauth = true
    }
}
