import XCTest
@testable import Sentwise

/// Covers `resetTransientSettingsMessages()` — the Settings-window close hook
/// that clears the panes' inline messages/errors so reopening starts clean
/// (item 90 follow-up: a plan-change error lingered across close/reopen).
@MainActor
final class AppStateSettingsResetTests: XCTestCase {

    private func makeAppState() -> AppState {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            managedAccountEmail: "marcus@example.com",
            managedAccountID: "clerk-user:user_marcus"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: PassiveLLM(),
            notifier: FakeDraftNotifier()
        )
        return appState
    }

    /// A do-nothing LLM double; this test never drives a network call. Only the
    /// two protocol requirements without defaults need bodies.
    private final class PassiveLLM: LLMProviding, @unchecked Sendable {
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
            throw LLMError.transport("not used")
        }
    }

    func testResetClearsEverySettingsPaneMessage() {
        let appState = makeAppState()

        // Every transient message/error a Settings pane can show.
        appState.connectionError = "conn"
        appState.fetchError = "fetch"
        appState.bodyError = "body"
        appState.draftError = "draft"
        appState.llmError = "llm"
        appState.managedError = "managed"
        appState.voiceError = "voice"
        appState.googleOAuthInterestError = "oauth"
        appState.signatureDetectionMessage = "sig"
        appState.transcriptFolderError = "transcript"
        appState.diagnosticsError = "diag"
        appState.manageBillingMessage = "billing"
        appState.planChangeMessage = "Could not change your plan."
        appState.planChangeFailed = true

        appState.resetTransientSettingsMessages()

        XCTAssertNil(appState.connectionError)
        XCTAssertNil(appState.fetchError)
        XCTAssertNil(appState.bodyError)
        XCTAssertNil(appState.draftError)
        XCTAssertNil(appState.llmError)
        XCTAssertNil(appState.managedError)
        XCTAssertNil(appState.voiceError)
        XCTAssertNil(appState.googleOAuthInterestError)
        XCTAssertNil(appState.signatureDetectionMessage)
        XCTAssertNil(appState.transcriptFolderError)
        XCTAssertNil(appState.diagnosticsError)
        XCTAssertNil(appState.manageBillingMessage)
        XCTAssertNil(appState.planChangeMessage)
        XCTAssertFalse(appState.planChangeFailed)
    }

    /// The draft/review flow's own status is intentionally out of scope — closing
    /// Settings must not wipe a draft-flow notification.
    func testResetLeavesDraftFlowStatusUntouched() {
        let appState = makeAppState()
        appState.draftSavedMessage = "Saved to drafts"
        appState.draftSentMessage = "Sent"

        appState.resetTransientSettingsMessages()

        XCTAssertEqual(appState.draftSavedMessage, "Saved to drafts")
        XCTAssertEqual(appState.draftSentMessage, "Sent")
    }
}
