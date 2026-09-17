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

    func testLaunchRestorationHonorsConnectedAccountLimit() {
        let third = "third@work.com"
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail): "gmail-pw",
            .mailAppPassword(email: att): "att-pw",
            .mailAppPassword(email: third): "third-pw"
        ])
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: gmail,
            savedAccounts: [
                SavedMailAccount(email: gmail, host: "imap.gmail.com", port: 993),
                SavedMailAccount(email: att, host: "imap.mail.att.net", port: 993),
                SavedMailAccount(email: third, host: "imap.work.com", port: 993)
            ]
        )
        let app = makeAppState(settings: settings, secrets: secrets)

        app.managedAccountStatus = status(plan: .starter)
        app.restoreBackgroundConnectedAccounts()
        XCTAssertTrue(app.backgroundConnectedAccounts.isEmpty)
        XCTAssertEqual(app.connectedAccountCount, 1)

        app.managedAccountStatus = status(plan: .pro)
        app.restoreBackgroundConnectedAccounts()
        XCTAssertEqual(app.backgroundConnectedAccounts.map(\.id), [att])
        XCTAssertEqual(app.connectedAccountCount, 2)
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

    func testDisconnectedFocusedAccountFreesTierSlotForNewConnect() async {
        let app = makeAppState()
        app.managedAccountStatus = status(plan: .starter)   // cap of 1

        await connect(app, email: gmail, host: "imap.gmail.com", password: "gmail-pw")
        XCTAssertTrue(app.isAccountConnected)

        // Disconnecting (keeping local data) leaves the persisted mailEmail but
        // flips isAccountConnected off, so the slot must free up.
        app.disconnectMail(purgeLocalData: false)
        XCTAssertFalse(app.isAccountConnected)

        // The real connect-time gate no longer counts the disconnected focused slot.
        XCTAssertTrue(app.passesConnectAccountGate(
            newEmail: att, connectedFocusedEmail: gmail, messageSurface: .shared
        ))

        await connect(app, email: att, host: "imap.mail.att.net", password: "att-pw")

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, att)
        XCTAssertNil(app.connectionError)
        XCTAssertEqual(app.connectedAccountCount, 1)
    }

    func testDisconnectingFocusedWithBackgroundFreesSlotAtCap() async {
        let app = makeAppState()
        app.managedAccountStatus = status(plan: .pro)   // cap of 2

        await connect(app, email: gmail, host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: att, host: "imap.mail.att.net", password: "att-pw")
        XCTAssertEqual(app.connectedAccountCount, 2)     // att focused + gmail background

        app.disconnectMail(purgeLocalData: false)        // disconnect the focused (att)
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.connectedAccountCount, 1)     // only the background account remains

        // With one slot free, a new mailbox may connect.
        XCTAssertTrue(app.passesConnectAccountGate(
            newEmail: "third@work.com", connectedFocusedEmail: att, messageSurface: .shared
        ))
        await connect(app, email: "third@work.com", host: "imap.work.com", password: "third-pw")

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertNil(app.connectionError)
        XCTAssertEqual(app.connectedAccountCount, 2)
    }

    func testReconnectingDisconnectedFocusedAtCapWithBackgroundIsBlocked() async {
        // Regression (item 99): the reconnect fast-path must not bypass the tier cap
        // for a *disconnected* focused mailbox. Repro: Pro user with att focused +
        // gmail background → disconnect att (its email stays persisted) → plan drops
        // to Starter (cap 1, gmail already fills it) → reconnect att. The persisted
        // email matches the focused key, but since att is no longer connected the
        // fast-path must not fire, so the cap check runs and blocks the reconnect.
        let app = makeAppState()
        app.managedAccountStatus = status(plan: .pro)   // cap of 2

        await connect(app, email: gmail, host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: att, host: "imap.mail.att.net", password: "att-pw")
        XCTAssertEqual(app.connectedAccountCount, 2)      // att focused + gmail background

        app.disconnectMail(purgeLocalData: false)         // disconnect focused (att)
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.connectedAccountCount, 1)       // only gmail background remains

        // Downgrade to Starter: gmail's single background slot fills the cap.
        app.managedAccountStatus = status(plan: .starter)

        // The gate must count gmail and block the att reconnect — the disconnected
        // focused email no longer earns a free reconnect fast-path.
        XCTAssertFalse(app.passesConnectAccountGate(
            newEmail: att, connectedFocusedEmail: att, messageSurface: .shared
        ))
        XCTAssertEqual(app.connectionError, app.accountLimitUpgradeMessage)

        // End to end: attempting the reconnect leaves att disconnected and gmail the
        // only connected account, with the upgrade prompt surfaced.
        await connect(app, email: att, host: "imap.mail.att.net", password: "att-pw")

        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.connectedAccountCount, 1)
        XCTAssertEqual(app.backgroundConnectedAccounts.map(\.id), [gmail])
        XCTAssertEqual(app.connectionError, app.accountLimitUpgradeMessage)
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
