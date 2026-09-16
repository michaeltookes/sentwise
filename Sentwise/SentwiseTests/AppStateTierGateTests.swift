import SentwiseMail
import XCTest
@testable import Sentwise

/// AppState's tier-gated connection limit and multi-account registry queries
/// (item 99). The gate keys off the live `/v1/me` plan, falling back to the
/// cached subscription snapshot when offline.
@MainActor
final class AppStateTierGateTests: XCTestCase {

    private func makeAppState(mailEmail: String = "me@gmail.com", connected: Bool = true) -> AppState {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: mailEmail): "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let store = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: connected ? mailEmail : "",
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        ))
        let appState = AppState(
            persistence: store,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        return appState
    }

    private func status(plan: ManagedSubscription.Plan) -> ManagedAccountStatus {
        ManagedAccountStatus(subscription: ManagedSubscription(plan: plan, status: .active))
    }

    func testLimitReadsLivePlan() {
        let app = makeAppState()
        app.managedAccountStatus = status(plan: .starter)
        XCTAssertEqual(app.currentSubscriptionPlan, .starter)
        XCTAssertEqual(app.connectedAccountLimit, 1)

        app.managedAccountStatus = status(plan: .unlimited)
        XCTAssertEqual(app.connectedAccountLimit, 5)
    }

    func testLimitFallsBackToCachedSnapshotWhenLiveUnknown() {
        let app = makeAppState()
        app.managedAccountStatus = nil
        app.cachedSubscriptionSnapshot = SubscriptionSnapshot(plan: .pro, status: .active, capturedAt: Date())
        XCTAssertEqual(app.currentSubscriptionPlan, .pro)
        XCTAssertEqual(app.connectedAccountLimit, 2)
    }

    func testStarterBlocksSecondAccount() {
        let app = makeAppState()
        app.managedAccountStatus = status(plan: .starter)

        XCTAssertEqual(app.connectedAccountCount, 1)          // the focused account
        XCTAssertFalse(app.canConnectAnotherAccount)          // Starter cap is 1
        // The already-connected account may always reconnect.
        XCTAssertTrue(app.canConnectAccount(email: "me@gmail.com"))
        // A new account is blocked.
        XCTAssertFalse(app.canConnectAccount(email: "other@work.com"))
    }

    func testProAllowsASecondAccount() {
        let app = makeAppState()
        app.managedAccountStatus = status(plan: .pro)

        XCTAssertEqual(app.connectedAccountCount, 1)
        XCTAssertTrue(app.canConnectAnotherAccount)
        XCTAssertTrue(app.canConnectAccount(email: "other@work.com"))
    }

    func testDisconnectedInstallHasZeroCountAndCanConnect() {
        let app = makeAppState(connected: false)
        app.managedAccountStatus = status(plan: .starter)

        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.connectedAccountCount, 0)
        XCTAssertTrue(app.canConnectAnotherAccount)
    }

    func testRegistryQueriesSpanFocusedAndBackgroundAccounts() {
        let app = makeAppState()
        let background = ConnectedMailAccount(
            email: "side@work.com", host: "imap.work.com", port: 993, appPassword: "side-pw"
        )
        app.backgroundConnectedAccounts = [background]

        XCTAssertEqual(app.connectedAccountCount, 2)
        XCTAssertTrue(app.isConnectedAccount(email: "me@gmail.com"))
        XCTAssertTrue(app.isConnectedAccount(email: "SIDE@work.com"))
        XCTAssertFalse(app.isConnectedAccount(email: "nope@work.com"))
        XCTAssertEqual(app.connectedCredentials(forAccountEmail: "side@work.com")?.appPassword, "side-pw")
        XCTAssertEqual(app.connectedCredentials(forAccountEmail: "me@gmail.com")?.email, "me@gmail.com")
        XCTAssertNil(app.connectedCredentials(forAccountEmail: "nope@work.com"))
    }
}
