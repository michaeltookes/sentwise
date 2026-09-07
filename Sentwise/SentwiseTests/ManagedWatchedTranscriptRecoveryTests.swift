import SentwiseMail
import XCTest
@testable import Sentwise

private actor ManagedWatchedTranscriptLLMProvider: LLMProviding {
    private let status: ManagedAccountStatus
    private var completionCount = 0

    init(status: ManagedAccountStatus) {
        self.status = status
    }

    func completions() -> Int {
        completionCount
    }

    func testConnection(
        provider: LLMProviderKind,
        apiKey: String,
        model: String,
        baseURL: String?
    ) async throws {}

    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        completionCount += 1
        return LLMResponse(text: "Follow up.")
    }

    func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
        status
    }
}

@MainActor
final class ManagedWatchedTranscriptRecoveryTests: XCTestCase {

    func testManagedLicenseRefreshRetriesDeferredWatchedTranscript() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-transcript-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let llm = ManagedWatchedTranscriptLLMProvider(status: activeStatus())
        let appState = makeSignedInAppState(folderURL: dir, llm: llm)
        appState.startTranscriptFolderWatchingIfEnabled()
        guard let source = appState.transcriptFolderSource else {
            return XCTFail("Expected transcript folder source")
        }
        defer { appState.stopTranscriptFolderWatching() }
        source.fileStabilityDelayNanoseconds = 0

        await source.scanForNewTranscripts()
        let transcript = dir.appendingPathComponent("call.txt")
        try "Marcus: recap.".write(to: transcript, atomically: true, encoding: .utf8)
        let snapshot = try XCTUnwrap(WatchedFolderFileSnapshot(url: transcript))
        source.rejectedDeliveries[WatchedFolderScanner.seenKey(for: transcript)] = WatchedFolderRejectedDeliveryState(
            snapshot: snapshot,
            attempts: 0,
            nextRetryAt: .distantFuture,
            isDeferred: true
        )

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertTrue(source.rejectedDeliveries.values.contains(where: \.isDeferred))
        let initialCompletions = await llm.completions()
        XCTAssertEqual(initialCompletions, 0)

        await appState.refreshManagedQuota()
        try await waitUntil { !appState.pendingDrafts.isEmpty }

        XCTAssertEqual(appState.pendingDrafts.count, 1)
        XCTAssertFalse(source.rejectedDeliveries.values.contains(where: \.isDeferred))
        let finalCompletions = await llm.completions()
        XCTAssertEqual(finalCompletions, 1)
        XCTAssertNil(appState.transcriptFolderError)
    }

    private func makeSignedInAppState(
        folderURL: URL,
        llm: LLMProviding
    ) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "me@gmail.com",
                llmProvider: "managed",
                llmModel: "",
                llmVerifiedModel: "",
                managedAccountEmail: "marcus@example.com",
                managedAccountID: "clerk-user:user_marcus",
                transcriptWatchedFolderEnabled: true,
                transcriptWatchedFolderPath: folderURL.path
            )),
            secrets: InMemorySecretStore(seed: [
                .mailAppPassword: "app-pw",
                .managedClientToken: "client_X",
                .managedSessionID: "sess_X"
            ]),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm
        )
    }

    private func activeStatus() -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active)
        )
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
