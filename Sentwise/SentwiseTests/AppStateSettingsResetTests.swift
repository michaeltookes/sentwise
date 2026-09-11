import SentwiseMail
import XCTest
@testable import Sentwise

/// Covers `resetTransientSettingsMessages()` — the Settings-window close hook
/// that clears the panes' inline messages/errors so reopening starts clean
/// (item 90 follow-up: a plan-change error lingered across close/reopen).
@MainActor
final class AppStateSettingsResetTests: XCTestCase {

    private func makeAppState(llm: LLMProviding = PassiveLLM()) -> AppState {
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
            llm: llm,
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

    func testResetClearsSettingsOwnedPaneMessages() {
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
        XCTAssertEqual(appState.bodyError, "body")
        XCTAssertEqual(appState.draftError, "draft")
        XCTAssertNil(appState.llmError)
        XCTAssertNil(appState.managedError)
        XCTAssertNil(appState.voiceError)
        XCTAssertNil(appState.googleOAuthInterestError)
        XCTAssertNil(appState.signatureDetectionMessage)
        XCTAssertEqual(appState.transcriptFolderError, "transcript")
        XCTAssertNil(appState.diagnosticsError)
        XCTAssertNil(appState.manageBillingMessage)
        XCTAssertNil(appState.planChangeMessage)
        XCTAssertFalse(appState.planChangeFailed)
    }

    func testResetLeavesPlanChangeOperationInFlight() async {
        let llm = SuspendedPlanChangeLLM()
        let appState = makeAppState(llm: llm)
        let starter = status(plan: .starter)
        let pro = status(plan: .pro)
        appState.managedAccountStatus = starter
        appState.markManagedAccountStatusFresh(from: starter)
        llm.statusToReturn = pro

        let planChange = Task {
            await appState.changePlan(
                to: .pro,
                reconcileRetryDelays: [],
                backgroundReconcileRetryDelays: []
            )
        }
        await fulfillment(of: [llm.didStartPlanChange], timeout: 1)
        let planChangeOperationGeneration = appState.planChangeOperationGeneration

        appState.resetTransientSettingsMessages()

        XCTAssertTrue(appState.isChangingPlan)
        XCTAssertEqual(appState.changingPlanTier, .pro)
        XCTAssertEqual(appState.planChangeOperationGeneration, planChangeOperationGeneration)

        llm.completePlanChange(with: .success(PaddlePlanChange(plan: .pro, status: .active)))
        await planChange.value

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertFalse(appState.isChangingPlan)
        XCTAssertNil(appState.changingPlanTier)
        XCTAssertNil(appState.planChangeMessage)
        XCTAssertFalse(appState.planChangeFailed)
    }

    func testResetSuppressesPendingPlanReconciliationConfirmation() async {
        let llm = SuspendedPlanChangeLLM()
        let appState = makeAppState(llm: llm)
        defer {
            appState.cancelScheduledManagedAccountStatusRefresh()
            appState.cancelPlanChangeReconciliation()
        }
        let starter = status(plan: .starter)
        let pendingPro = status(plan: .pro, quota: nil)
        let confirmedPro = status(plan: .pro)
        appState.managedAccountStatus = starter
        appState.markManagedAccountStatusFresh(from: starter)
        llm.statusToReturn = pendingPro

        let planChange = Task {
            await appState.changePlan(
                to: .pro,
                reconcileRetryDelays: [],
                backgroundReconcileRetryDelays: []
            )
        }
        await fulfillment(of: [llm.didStartPlanChange], timeout: 1)

        appState.resetTransientSettingsMessages()
        llm.completePlanChange(with: .success(PaddlePlanChange(plan: .pro, status: .active)))
        await planChange.value

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertNil(appState.planChangeMessage)
        XCTAssertFalse(appState.planChangeFailed)
        XCTAssertNotNil(appState.pendingPlanChangeReconciliation)

        llm.statusToReturn = confirmedPro
        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.currentSubscriptionPlanTier, .pro)
        XCTAssertNil(appState.planChangeMessage)
        XCTAssertFalse(appState.planChangeFailed)
        XCTAssertNil(appState.pendingPlanChangeReconciliation)
    }

    func testResetSuppressesStaleLLMProviderError() async {
        let llm = SuspendedLLMConnectionTester()
        let appState = makeAppState(llm: llm)
        appState.selectLLMProvider(.anthropic)
        appState.llmAPIKey = "sk-live"

        let testConnection = Task { await appState.testLLMConnection() }
        await fulfillment(of: [llm.didStartConnectionTest], timeout: 1)

        appState.resetTransientSettingsMessages()
        llm.complete(with: .failure(LLMError.http(status: 401, message: "bad key")))
        await testConnection.value

        XCTAssertNil(appState.llmError)
        XCTAssertFalse(appState.isTestingLLM)
        XCTAssertFalse(appState.isLLMConnected)
    }

    func testResetSuppressesStaleVoiceLearningError() async {
        let mailProvider = SuspendedRecentMessagesMailProvider()
        let appState = AppState(
            persistence: AppStateMemoryPersistence(settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: "marcus@example.com",
                mailHost: "imap.example.com",
                mailPort: 993,
                llmProvider: "ollama",
                llmVerifiedModel: LLMProviderKind.ollama.defaultModel
            )),
            secrets: InMemorySecretStore(seed: [
                .mailAppPassword(email: "marcus@example.com"): "app-password"
            ]),
            mailProvider: mailProvider,
            llm: PassiveLLM(),
            notifier: FakeDraftNotifier()
        )

        let learnVoice = Task { await appState.learnVoiceProfile() }
        await fulfillment(of: [mailProvider.didStartFetchRecentMessages], timeout: 1)

        appState.resetTransientSettingsMessages()
        mailProvider.completeFetchRecentMessages(with: .failure(MailError.connectionFailed("offline")))
        await learnVoice.value

        XCTAssertNil(appState.voiceError)
        XCTAssertFalse(appState.isLearningVoice)
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

    private func status(plan: ManagedSubscription.Plan) -> ManagedAccountStatus {
        status(
            plan: plan,
            quota: ManagedQuota(used: 1, limit: 120, remaining: 119, resetsAt: Date(), tokenLimit: 1_200)
        )
    }

    private func status(plan: ManagedSubscription.Plan, quota: ManagedQuota?) -> ManagedAccountStatus {
        ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            quota: quota,
            subscription: ManagedSubscription(plan: plan, status: .active, renewsAt: nil, manageBillingURL: nil)
        )
    }

    private final class SuspendedPlanChangeLLM: LLMProviding, @unchecked Sendable {
        let didStartPlanChange = XCTestExpectation(description: "plan change started")
        var statusToReturn: ManagedAccountStatus?
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PaddlePlanChange, Error>?

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

        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
            statusToReturn
        }

        func changeManagedPlan(priceID: String, expectedAccountKey: String?) async throws -> PaddlePlanChange {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                didStartPlanChange.fulfill()
            }
        }

        func completePlanChange(with result: Result<PaddlePlanChange, Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    private final class SuspendedRecentMessagesMailProvider: MailProvider, @unchecked Sendable {
        let didStartFetchRecentMessages = XCTestExpectation(description: "recent messages fetch started")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[MailMessage], Error>?

        func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

        func fetchRecentMessages(
            _ credentials: MailAccountCredentials,
            mailbox: Mailbox,
            limit: Int
        ) async throws -> [MailMessage] {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                didStartFetchRecentMessages.fulfill()
            }
        }

        func fetchBodyText(
            _ credentials: MailAccountCredentials,
            mailbox: Mailbox,
            uid: UInt32,
            expectedUIDValidity: UInt32?
        ) async throws -> Data {
            Data()
        }

        func appendMessage(
            _ credentials: MailAccountCredentials,
            mailbox: Mailbox,
            rfc822: Data,
            flags: [MailFlag]
        ) async throws {}

        func completeFetchRecentMessages(with result: Result<[MailMessage], Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
