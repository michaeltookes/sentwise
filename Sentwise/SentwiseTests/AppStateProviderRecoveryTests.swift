import SentwiseMail
import XCTest
@testable import Sentwise

private actor ProviderRecoveryTranscriptLLM: LLMProviding {
    private var completionCount = 0

    func completions() -> Int {
        completionCount
    }

    func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
    func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
        completionCount += 1
        return LLMResponse(text: "Follow up.")
    }
}

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

    func testStoredOpenRouterSelectionResumesWatcherAndDeferredTranscripts() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-transcript-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let llm = ProviderRecoveryTranscriptLLM()
        let secrets = InMemorySecretStore(seed: [
            .openRouterAPIKey: "sk-or-existing"
        ])
        let appState = makeAppState(secrets: secrets, llm: llm)
        prepareWatcherPausedByManagedLicenseGate(appState)
        appState.transcriptWatchedFolderEnabled = true
        appState.transcriptWatchedFolderPath = dir.path
        appState.startTranscriptFolderWatchingIfEnabled()
        guard let source = appState.transcriptFolderSource else {
            return XCTFail("Expected transcript folder source")
        }
        defer { appState.stopTranscriptFolderWatching() }
        source.fileStabilityDelayNanoseconds = 0
        let transcript = dir.appendingPathComponent("call.txt")
        try "Marcus: recap.".write(to: transcript, atomically: true, encoding: .utf8)
        let snapshot = try XCTUnwrap(WatchedFolderFileSnapshot(url: transcript))
        source.rejectedDeliveries[WatchedFolderScanner.seenKey(for: transcript)] = WatchedFolderRejectedDeliveryState(
            snapshot: snapshot,
            attempts: 0,
            nextRetryAt: .distantFuture,
            isDeferred: true
        )

        appState.selectLLMProvider(.openAICompatible)
        try await waitUntil { !appState.pendingDrafts.isEmpty }

        XCTAssertEqual(appState.watchStatus, .watching)
        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertFalse(source.rejectedDeliveries.values.contains(where: \.isDeferred))
        let completions = await llm.completions()
        XCTAssertEqual(completions, 1)
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

    private func waitUntil(
        timeoutIterations: Int = 100,
        condition: () async -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
