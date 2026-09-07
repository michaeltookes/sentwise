import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateFollowUpManagedLicenseTests: XCTestCase {

    private final class ManagedStatusLLM: LLMProviding, @unchecked Sendable {
        var statusToReturn: ManagedAccountStatus?
        private(set) var statusFetchCount = 0
        private(set) var lastRequest: LLMRequest?

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(
            _ request: LLMRequest,
            provider: LLMProviderKind,
            apiKey: String,
            baseURL: String?
        ) async throws -> LLMResponse {
            lastRequest = request
            return LLMResponse(text: "Hi team,\n\nGreat call. I'll send the deck Friday.")
        }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
            statusFetchCount += 1
            return statusToReturn
        }
        func fetchManagedQuota() async throws -> ManagedQuota? { statusToReturn?.quota }
        func deleteManagedAccount() async throws {}
    }

    func testCanCreateFollowUpAllowsStaleManagedLicenseRecovery() async throws {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com",
            managedAccountID: "clerk-user:user_marcus"
        ))
        let llm = ManagedStatusLLM()
        llm.statusToReturn = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active)
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: FakeDraftNotifier()
        )
        appState.subscriptionCacheStore = EmptySubscriptionCacheStore()
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .pastDue,
            capturedAt: Date()
        )
        appState.mailAppPassword = "app-pw"

        XCTAssertEqual(appState.managedLicense, .notEntitled)
        XCTAssertTrue(appState.canCreateFollowUp)

        let draft = try await appState.createFollowUp(
            from: TranscriptIngest.fromPaste("Marcus: ship the deck Friday."),
            recipients: [MailAddress(email: "dana@example.com")]
        )

        XCTAssertEqual(llm.statusFetchCount, 1)
        XCTAssertEqual(appState.managedLicense, .entitled)
        XCTAssertTrue(draft.body.contains("Great call"))
        XCTAssertNotNil(llm.lastRequest)
    }
}

private final class EmptySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
    func snapshot(accountKey: String) -> SubscriptionSnapshot? { nil }
    func save(_ snapshot: SubscriptionSnapshot, accountKey: String) {}
    func clear(accountKey: String) {}
}
