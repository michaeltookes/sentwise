import XCTest
@testable import Sentwise

/// AppState-level behavior for the Account & subscription pane (item 73): the
/// delete-account flow (success clears credentials, failure keeps them, hunt-mode
/// no-op), the `/v1/me` status mirror, and the usage-alert → Subscription routing.
@MainActor
final class AppStateSubscriptionTests: XCTestCase {

    // MARK: - Doubles

    /// An `LLMProviding` whose `deleteManagedAccount()` succeeds or throws.
    private final class DeletableLLMProvider: LLMProviding, @unchecked Sendable {
        var deleteError: Error?
        var statusToReturn: ManagedAccountStatus?
        private(set) var deleteCount = 0

        func testConnection(provider: LLMProviderKind, apiKey: String, model: String, baseURL: String?) async throws {}
        func complete(_ request: LLMRequest, provider: LLMProviderKind, apiKey: String, baseURL: String?) async throws -> LLMResponse {
            LLMResponse(text: "")
        }
        func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? { statusToReturn }
        func fetchManagedQuota() async throws -> ManagedQuota? { statusToReturn?.quota }
        func deleteManagedAccount() async throws {
            deleteCount += 1
            if let deleteError { throw deleteError }
        }
    }

    // MARK: - Fixture

    private func makeSignedInAppState(
        email: String = "marcus@example.com",
        llm: LLMProviding,
        notifier: FakeDraftNotifier = FakeDraftNotifier()
    ) -> (AppState, SecretStore) {
        let secrets = InMemorySecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmModel: "",
            llmVerifiedModel: "",
            managedAccountEmail: email,
            managedAccountID: "clerk-user:\(email.lowercased())"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: llm,
            notifier: notifier
        )
        return (appState, secrets)
    }

    // MARK: - Delete flow

    func testDeleteAccountSuccessClearsCredentials() async {
        let llm = DeletableLLMProvider()
        let (appState, secrets) = makeSignedInAppState(llm: llm)
        XCTAssertTrue(appState.isManagedSignedIn)

        let ok = await appState.deleteManagedAccount(isHuntMode: false)

        XCTAssertTrue(ok)
        XCTAssertEqual(llm.deleteCount, 1)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertTrue(appState.managedAccountEmail.isEmpty)
        XCTAssertTrue(appState.didDeleteManagedAccount)
        XCTAssertNil(appState.managedError)
        // Credentials removed from the Keychain (sign-out semantics).
        XCTAssertNil((try? secrets.value(for: .managedClientToken)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .managedSessionID)) ?? nil)
    }

    func testDeleteAccountFailureKeepsAccountAndShowsMessage() async {
        let llm = DeletableLLMProvider()
        llm.deleteError = LLMError.managedAccountDeletionFailed("We couldn't delete your account.")
        let (appState, secrets) = makeSignedInAppState(llm: llm)

        let ok = await appState.deleteManagedAccount(isHuntMode: false)

        XCTAssertFalse(ok)
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertEqual(appState.managedError, "We couldn't delete your account.")
        XCTAssertFalse(appState.didDeleteManagedAccount)
        XCTAssertNotNil((try? secrets.value(for: .managedClientToken)) ?? nil)
    }

    func testDeleteAccountHuntModeIsNoOp() async {
        let llm = DeletableLLMProvider()
        let (appState, secrets) = makeSignedInAppState(llm: llm)

        let ok = await appState.deleteManagedAccount(isHuntMode: true)

        XCTAssertTrue(ok, "hunt-mode delete reports success without touching a real account")
        XCTAssertEqual(llm.deleteCount, 0, "hunt-mode delete must not call the network")
        XCTAssertTrue(appState.isManagedSignedIn, "hunt-mode delete must not tear down the fixture")
        XCTAssertFalse(appState.didDeleteManagedAccount)
        XCTAssertNotNil((try? secrets.value(for: .managedClientToken)) ?? nil)
    }

    // MARK: - Status mirror

    func testRefreshMirrorsFullStatus() async {
        let llm = DeletableLLMProvider()
        llm.statusToReturn = ManagedAccountStatus(
            userID: "clerk-user:marcus@example.com",
            email: "marcus@example.com",
            trial: ManagedTrial(endsAt: ManagedQuotaDate.date(from: "2026-09-01T00:00:00Z"), active: true),
            quota: nil,
            subscription: ManagedSubscription(plan: .individual, status: .active,
                                               renewsAt: ManagedQuotaDate.date(from: "2026-10-01T00:00:00Z"))
        )
        let (appState, _) = makeSignedInAppState(llm: llm)

        await appState.refreshManagedQuota()

        XCTAssertEqual(appState.managedAccountStatus?.subscription?.plan, .individual)
        XCTAssertEqual(appState.managedAccountStatus?.email, "marcus@example.com")
    }

    // MARK: - Usage-alert routing (item 73)

    func testUsageAlertOpenRoutesToSubscriptionTab() async {
        let notifier = FakeDraftNotifier()
        let (appState, _) = makeSignedInAppState(llm: DeletableLLMProvider(), notifier: notifier)
        var opened: SettingsTab?
        appState.openSettingsHandler = { opened = $0 }

        await notifier.fireOpenUsageSettings()

        XCTAssertEqual(opened, .subscription)
    }
}
