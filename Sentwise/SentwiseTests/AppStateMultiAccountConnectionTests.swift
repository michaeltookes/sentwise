import SentwiseMail
import XCTest
@testable import Sentwise

/// Concurrent connections and the tier gate (item 99): connecting a second mailbox
/// keeps the first connected, the plan's account cap blocks over-limit connects
/// with an upgrade prompt, saved accounts restore as connected at launch, and a
/// background account can be disconnected on its own.
@MainActor
final class AppStateMultiAccountConnectionTests: XCTestCase {

    private let gmail = "me@gmail.com"
    private let att = "me@att.net"

    private func makeAppState(
        settings: Settings = .default,
        secrets: SecretStore = InMemorySecretStore()
    ) -> AppState {
        AppState(
            persistence: AppStateMemoryPersistence(settings: settings),
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    private func connect(_ app: AppState, email: String, host: String, password: String) async {
        app.mailEmail = email
        app.mailHost = host
        app.mailPort = 993
        app.mailAppPassword = password
        await app.testConnection()
    }

    private func status(plan: ManagedSubscription.Plan) -> ManagedAccountStatus {
        ManagedAccountStatus(subscription: ManagedSubscription(plan: plan, status: .active))
    }

    func testConnectingSecondAccountKeepsTheFirstConnected() async {
        let app = makeAppState()          // no plan → lenient default cap (2)

        await connect(app, email: gmail, host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: att, host: "imap.mail.att.net", password: "att-pw")

        // Both mailboxes are connected concurrently; the second is focused, the
        // first stays connected in the background.
        XCTAssertEqual(app.mailEmail, att)
        XCTAssertEqual(app.connectedAccountCount, 2)
        XCTAssertTrue(app.isConnectedAccount(email: gmail))
        XCTAssertTrue(app.isConnectedAccount(email: att))
        XCTAssertEqual(app.backgroundConnectedAccounts.map(\.id), [gmail])
        XCTAssertNil(app.connectionError)
    }

    func testStarterPlanBlocksASecondConnectWithUpgradePrompt() async {
        let app = makeAppState()
        app.managedAccountStatus = status(plan: .starter)   // cap of 1

        await connect(app, email: gmail, host: "imap.gmail.com", password: "gmail-pw")
        XCTAssertEqual(app.connectedAccountCount, 1)

        await connect(app, email: att, host: "imap.mail.att.net", password: "att-pw")

        // The second connect is blocked; the first stays the only connected account.
        XCTAssertEqual(app.connectedAccountCount, 1)
        XCTAssertTrue(app.backgroundConnectedAccounts.isEmpty)
        XCTAssertEqual(app.connectionError, app.accountLimitUpgradeMessage)
    }

    func testProPlanAllowsTwoButBlocksAThird() async {
        let app = makeAppState()
        app.managedAccountStatus = status(plan: .pro)   // cap of 2

        await connect(app, email: gmail, host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: att, host: "imap.mail.att.net", password: "att-pw")
        XCTAssertEqual(app.connectedAccountCount, 2)

        await connect(app, email: "third@work.com", host: "imap.work.com", password: "third-pw")

        // Blocked: still exactly the two connected mailboxes (gmail background, att
        // focused); the third never entered the background registry.
        XCTAssertEqual(app.connectedAccountCount, 2)
        XCTAssertEqual(Set(app.backgroundConnectedAccounts.map(\.id)), [gmail])
        XCTAssertFalse(app.backgroundConnectedAccounts.contains { $0.id == "third@work.com" })
        XCTAssertEqual(app.connectionError, app.accountLimitUpgradeMessage)
    }

    func testLaunchRestoresSavedAccountsAsConcurrentlyConnected() {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail): "gmail-pw",
            .mailAppPassword(email: att): "att-pw"
        ])
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: gmail,
            savedAccounts: [
                SavedMailAccount(email: gmail, host: "imap.gmail.com", port: 993),
                SavedMailAccount(email: att, host: "imap.mail.att.net", port: 993)
            ]
        )

        let app = makeAppState(settings: settings, secrets: secrets)

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.connectedAccountCount, 2)
        XCTAssertEqual(app.backgroundConnectedAccounts.map(\.id), [att])
        XCTAssertEqual(app.connectedCredentials(forAccountEmail: att)?.appPassword, "att-pw")
    }

    func testDisconnectBackgroundAccountRemovesOnlyThatAccount() {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail): "gmail-pw",
            .mailAppPassword(email: att): "att-pw"
        ])
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: gmail,
            savedAccounts: [
                SavedMailAccount(email: gmail, host: "imap.gmail.com", port: 993),
                SavedMailAccount(email: att, host: "imap.mail.att.net", port: 993)
            ]
        )
        let app = makeAppState(settings: settings, secrets: secrets)
        let background = try? XCTUnwrap(app.backgroundConnectedAccounts.first)

        if let background { app.disconnectBackgroundAccount(background) }

        XCTAssertTrue(app.backgroundConnectedAccounts.isEmpty)
        XCTAssertEqual(app.connectedAccountCount, 1)
        XCTAssertTrue(app.isConnectedAccount(email: gmail))
        XCTAssertFalse(app.isConnectedAccount(email: att))
    }

    func testEraseAllLocalDataClearsEveryConnectedAccount() async {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail): "gmail-pw",
            .mailAppPassword(email: att): "att-pw"
        ])
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: gmail,
            savedAccounts: [
                SavedMailAccount(email: gmail, host: "imap.gmail.com", port: 993),
                SavedMailAccount(email: att, host: "imap.mail.att.net", port: 993)
            ]
        )
        let app = makeAppState(settings: settings, secrets: secrets)
        XCTAssertEqual(app.connectedAccountCount, 2)

        _ = await app.eraseAllLocalData()

        XCTAssertTrue(app.backgroundConnectedAccounts.isEmpty)
        XCTAssertEqual(app.connectedAccountCount, 0)
        XCTAssertTrue(app.savedAccounts.isEmpty)
        XCTAssertFalse(app.isAccountConnected)
    }
}
