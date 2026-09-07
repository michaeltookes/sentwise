import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateManagedEntitlementErrorTests: XCTestCase {
    private let billingMessage = "Payment required."
    private let portalURL = "https://billing.example/portal"

    func testGenerateDraftSurfacesManagedEntitlementErrorAfterBlockingSnapshot() async {
        let appState = makeManagedAppState(
            mailProvider: FakeAppMailProvider(
                result: .success(()),
                bodyResult: .success(Data("Can you make Thursday?".utf8))
            ),
            llm: FakeLLMProvider(
                result: .success(()),
                completion: .failure(.managedTrialExpired(billingMessage))
            )
        )
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }

        let draft = await appState.generateDraft(for: inboxMessage())

        XCTAssertNil(draft)
        XCTAssertNil(appState.generatedDraft)
        XCTAssertEqual(appState.draftError, billingMessage)
        XCTAssertEqual(appState.managedLicense, .notEntitled)
        XCTAssertTrue(appState.canManageBilling)
        XCTAssertFalse(appState.shouldOfferSubscribe)
    }

    func testLearnVoiceProfileSurfacesManagedEntitlementErrorAfterBlockingSnapshot() async {
        let appState = makeManagedAppState(
            mailProvider: FakeAppMailProvider(
                result: .success(()),
                fetchResult: .success([sentMessage()]),
                bodyResult: .success(Data("Hi,\n\nSounds good.\n\nBest,\nMichael".utf8))
            ),
            llm: FakeLLMProvider(
                result: .success(()),
                completion: .failure(.managedTrialExpired(billingMessage))
            )
        )
        defer { appState.cancelScheduledManagedAccountStatusRefresh() }

        await appState.learnVoiceProfile()

        XCTAssertNil(appState.voiceProfile)
        XCTAssertEqual(appState.voiceError, billingMessage)
        XCTAssertEqual(appState.managedLicense, .notEntitled)
        XCTAssertTrue(appState.canManageBilling)
        XCTAssertFalse(appState.shouldOfferSubscribe)
    }

    private func makeManagedAppState(mailProvider: MailProvider, llm: LLMProviding) -> AppState {
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
        let appState = AppState(persistence: persistence, secrets: secrets, mailProvider: mailProvider, llm: llm)
        appState.subscriptionCacheStore = InMemorySubscriptionCacheStore()
        appState.mailAppPassword = "app-pw"
        let active = ManagedAccountStatus(
            userID: "user_marcus",
            email: "marcus@example.com",
            subscription: ManagedSubscription(plan: .pro, status: .active, manageBillingURL: portalURL)
        )
        appState.managedAccountStatus = active
        appState.markManagedAccountStatusFresh(from: active)
        appState.cachedSubscriptionSnapshot = SubscriptionSnapshot(
            plan: .pro,
            status: .active,
            manageBillingURL: portalURL,
            capturedAt: Date()
        )
        return appState
    }

    private func inboxMessage() -> MailMessage {
        MailMessage(
            id: 5,
            from: MailAddress(name: "Alice", email: "alice@x.com"),
            replyTo: MailAddress(name: "Team", email: "team@x.com"),
            subject: "Lunch?",
            date: ""
        )
    }

    private func sentMessage() -> MailMessage {
        MailMessage(id: 1, from: MailAddress(email: "me@gmail.com"), subject: "Re: Plan", date: "")
    }

    private final class InMemorySubscriptionCacheStore: SubscriptionCacheStoring, @unchecked Sendable {
        private var snapshots: [String: SubscriptionSnapshot] = [:]

        func snapshot(accountKey: String) -> SubscriptionSnapshot? { snapshots[accountKey] }
        func save(_ snapshot: SubscriptionSnapshot, accountKey: String) { snapshots[accountKey] = snapshot }
        func clear(accountKey: String) { snapshots.removeValue(forKey: accountKey) }
    }
}
