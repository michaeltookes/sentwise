import SentwiseMail
import XCTest
@testable import Sentwise

/// Tests for saved accounts (item 48): the v10→v11 migration, per-account
/// Keychain secrets, one-tap switching that retains every account's credentials,
/// removal that deletes only one account's secret, and persistence across relaunch.
@MainActor
final class AppStateSavedAccountsTests: XCTestCase {

    private func makeAppState(
        settings: Settings = .default,
        secrets: SecretStore = InMemorySecretStore(),
        persistence: AppStateMemoryPersistence? = nil,
        provider: MailProvider = FakeAppMailProvider(result: .success(()))
    ) -> (AppState, AppStateMemoryPersistence, SecretStore) {
        let store = persistence ?? AppStateMemoryPersistence(settings: settings)
        let app = AppState(
            persistence: store,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        return (app, store, secrets)
    }

    /// Connects `email` with `password` through the normal verify path.
    private func connect(_ app: AppState, email: String, host: String, password: String) async {
        app.mailEmail = email
        app.mailHost = host
        app.mailPort = 993
        app.mailAppPassword = password
        await app.testConnection()
    }

    // MARK: - Migration (v10 → v11)

    func testMigrationMovesLegacySecretAndSeedsSavedAccount() {
        let secrets = InMemorySecretStore(seed: [.mailAppPassword: "legacy-pw"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: 10,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            mailHost: "imap.gmail.com",
            mailPort: 993
        ))
        let (app, store, _) = makeAppState(secrets: secrets, persistence: persistence)

        // The existing account becomes the first saved account.
        XCTAssertEqual(app.savedAccounts, [
            SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        ])
        // The secret moved to the per-account key and the legacy slot is gone.
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")), "legacy-pw")
        XCTAssertNil((try? secrets.value(for: .mailAppPassword)) ?? nil)
        // The upgraded settings were persisted at the new schema version.
        XCTAssertEqual(store.loadSettings().schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(store.loadSettings().savedAccounts.map(\.email), ["me@gmail.com"])
        // The account is still connected, from the migrated per-account secret.
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailAppPassword, "legacy-pw")
    }

    func testMigrationIsIdempotentAcrossRelaunch() {
        let secrets = InMemorySecretStore(seed: [.mailAppPassword: "legacy-pw"])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: 10,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            mailHost: "imap.gmail.com",
            mailPort: 993
        ))
        _ = makeAppState(secrets: secrets, persistence: persistence)
        // A second launch over the already-migrated store must not duplicate.
        let (relaunched, _, _) = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertEqual(relaunched.savedAccounts.map(\.email), ["me@gmail.com"])
        XCTAssertNil((try? secrets.value(for: .mailAppPassword)) ?? nil)
        XCTAssertTrue(relaunched.isAccountConnected)
    }

    func testMigrationWithNoAccountJustBumpsSchema() {
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: 10,
            pollIntervalSeconds: 300,
            mailEmail: ""
        ))
        let (app, store, _) = makeAppState(persistence: persistence)

        XCTAssertTrue(app.savedAccounts.isEmpty)
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(store.loadSettings().schemaVersion, Settings.currentSchemaVersion)
    }

    // MARK: - Add / per-account secret CRUD

    func testConnectingRemembersAccountUnderPerAccountKey() async {
        let secrets = InMemorySecretStore()
        let (app, store, _) = makeAppState(secrets: secrets)

        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.savedAccounts.map(\.email), ["me@gmail.com"])
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")), "gmail-pw")
        XCTAssertEqual(store.loadSettings().savedAccounts.map(\.email), ["me@gmail.com"])
    }

    func testConnectingSecondAccountKeepsBothSecrets() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)

        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        XCTAssertEqual(app.savedAccounts.map(\.email), ["me@gmail.com", "me@att.net"])
        // Connecting the second account did NOT overwrite the first's secret.
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")), "gmail-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@att.net")), "att-pw")
        XCTAssertTrue(app.isActiveAccount(app.savedAccounts[1]))
        XCTAssertFalse(app.isActiveAccount(app.savedAccounts[0]))
    }

    func testChangingConnectedAccountClearsSignaturePreferences() async {
        let secrets = InMemorySecretStore()
        let (app, store, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        app.signaturePolicy = .custom
        app.signatureText = "Best,\nGmail Me"

        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        XCTAssertTrue(app.isActiveAccount(SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)))
        XCTAssertEqual(app.signaturePolicy, .none)
        XCTAssertEqual(app.signatureText, "")
        XCTAssertEqual(store.loadSettings().signaturePolicy, SignaturePolicy.none.rawValue)
        XCTAssertEqual(store.loadSettings().signatureText, "")
        XCTAssertEqual(
            app.signatureDetectionMessage,
            "Signature cleared because the email account changed. Suggest or enter a signature for this account."
        )
        XCTAssertEqual(app.signatureDetectionSucceeded, false)
    }

    // MARK: - Switching

    func testSwitchToSavedAccountRetainsBothCredentials() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        await app.switchToSavedAccount(gmail)

        XCTAssertNil(app.connectionError)
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "me@gmail.com")
        XCTAssertEqual(app.mailAppPassword, "gmail-pw")
        XCTAssertTrue(app.isActiveAccount(gmail))
        // Both accounts' secrets survive the switch.
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")), "gmail-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@att.net")), "att-pw")
    }

    func testSwitchPreservesPendingDrafts() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        let draft = Draft(
            id: 42,
            sourceUIDValidity: 7,
            sourceAccountEmail: "me@att.net",
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: "Hi",
            sourceFrom: MailAddress(email: "friend@att.net"),
            sourceReplyTo: nil,
            sourceMessageID: "<msg-42@att.net>",
            replySubject: "Re: Hi",
            body: "Reply",
            model: "test-model",
            generatedAt: Date()
        )
        app.pendingDrafts = [draft]

        await app.switchToSavedAccount(
            SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        )

        // Pending drafts are account-scoped by identity, so switching leaves them.
        XCTAssertEqual(app.pendingDrafts.map(\.id), [42])
    }

    func testSwitchingToActiveAccountIsANoOp() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")

        let active = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        await app.switchToSavedAccount(active)

        XCTAssertNil(app.connectionError)
        XCTAssertTrue(app.isActiveAccount(active))
    }

    func testSwitchWithoutStoredSecretSurfacesError() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")

        // A saved account whose secret was never stored (e.g. removed) cannot
        // silently connect — the user is told to reconnect.
        let orphan = SavedMailAccount(email: "ghost@att.net", host: "imap.mail.att.net", port: 993)
        await app.switchToSavedAccount(orphan)

        XCTAssertNotNil(app.connectionError)
        XCTAssertEqual(app.mailEmail, "me@gmail.com", "active account unchanged")
    }

    func testSwitchFailureRestoresOutgoingAccount() async {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let att = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: att.email,
            mailHost: att.host,
            mailPort: att.port,
            savedAccounts: [gmail, att]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail.email): "expired-gmail-pw",
            .mailAppPassword(email: att.email): "att-pw"
        ])
        let provider = FakeAppMailProvider(result: .failure(.authenticationFailed("expired password")))
        let (app, store, _) = makeAppState(settings: settings, secrets: secrets, provider: provider)

        await app.switchToSavedAccount(gmail)

        XCTAssertNotNil(app.connectionError)
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(provider.lastCredentials?.email, gmail.email)
        XCTAssertEqual(provider.lastCredentials?.appPassword, "expired-gmail-pw")
        XCTAssertEqual(app.mailEmail, att.email)
        XCTAssertEqual(app.mailHost, att.host)
        XCTAssertEqual(app.mailPort, att.port)
        XCTAssertEqual(app.mailAppPassword, "att-pw")
        XCTAssertTrue(app.isActiveAccount(att))
        XCTAssertFalse(app.isActiveAccount(gmail))
        XCTAssertEqual(store.loadSettings().mailEmail, att.email)
    }

    func testExplicitConnectionFailureLeavesActiveAccountUntouched() async {
        let active = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: active.email,
            mailHost: active.host,
            mailPort: active.port,
            savedAccounts: [active]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: active.email): "att-pw"
        ])
        let provider = FakeAppMailProvider(result: .failure(.authenticationFailed("expired password")))
        let (app, store, _) = makeAppState(settings: settings, secrets: secrets, provider: provider)

        await app.testConnection(with: MailAccountCredentials(
            email: "me@gmail.com",
            appPassword: "expired-gmail-pw",
            host: "imap.gmail.com",
            port: 993
        ))

        XCTAssertNotNil(app.connectionError)
        XCTAssertEqual(provider.lastCredentials?.email, "me@gmail.com")
        XCTAssertEqual(provider.lastCredentials?.appPassword, "expired-gmail-pw")
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, active.email)
        XCTAssertEqual(app.mailHost, active.host)
        XCTAssertEqual(app.mailPort, active.port)
        XCTAssertEqual(app.mailAppPassword, "att-pw")
        XCTAssertTrue(app.isActiveAccount(active))
        XCTAssertEqual(store.loadSettings().mailEmail, active.email)
        XCTAssertEqual(store.loadSettings().savedAccounts, [active])
    }

    // MARK: - Removal

    func testRemoveInactiveAccountDeletesOnlyItsSecret() async {
        let secrets = InMemorySecretStore()
        let (app, _, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        app.removeSavedAccount(gmail)

        XCTAssertNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts.map(\.email), ["me@att.net"])
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: "me@gmail.com"))) ?? nil)
        // The still-active account's secret is untouched.
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@att.net")), "att-pw")
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "me@att.net")
    }

    func testRemoveActiveAccountGoesOffline() async {
        let secrets = InMemorySecretStore()
        let (app, store, _) = makeAppState(secrets: secrets)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")

        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        app.removeSavedAccount(gmail)

        XCTAssertTrue(app.savedAccounts.isEmpty)
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: "me@gmail.com"))) ?? nil)
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "")
        XCTAssertTrue(store.loadSettings().savedAccounts.isEmpty)
    }

    func testRemoveInactiveAccountRollsBackWhenSettingsSaveFails() {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let att = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: att.email,
            mailHost: att.host,
            mailPort: att.port,
            savedAccounts: [gmail, att]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail.email): "gmail-pw",
            .mailAppPassword(email: att.email): "att-pw"
        ])
        let persistence = AppStateMemoryPersistence(settings: settings)
        persistence.syncSaveError = AppStatePersistenceError.writeDenied
        let (app, store, _) = makeAppState(secrets: secrets, persistence: persistence)

        app.removeSavedAccount(gmail)

        XCTAssertNotNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts, [gmail, att])
        XCTAssertEqual(app.mailEmail, att.email)
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(store.loadSettings().savedAccounts, [gmail, att])
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: gmail.email)), "gmail-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: att.email)), "att-pw")
    }

    func testRemoveInactiveLegacyBackedAccountDeletesLegacySecret() {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let att = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: att.email,
            mailHost: att.host,
            mailPort: att.port,
            savedAccounts: [gmail, att]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "legacy-gmail-pw",
            .mailAppPassword(email: att.email): "att-pw"
        ])
        let (app, store, _) = makeAppState(settings: settings, secrets: secrets)

        app.removeSavedAccount(gmail)

        XCTAssertNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts, [att])
        XCTAssertEqual(store.loadSettings().savedAccounts, [att])
        XCTAssertNil((try? secrets.value(for: .mailAppPassword)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: gmail.email))) ?? nil)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: att.email)), "att-pw")
        XCTAssertNil(app.storedMailPassword(forEmail: gmail.email))
    }

    func testRemoveInactiveLegacyBackedAccountRollsBackLegacyWhenSettingsSaveFails() {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let att = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: att.email,
            mailHost: att.host,
            mailPort: att.port,
            savedAccounts: [gmail, att]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "legacy-gmail-pw",
            .mailAppPassword(email: att.email): "att-pw"
        ])
        let persistence = AppStateMemoryPersistence(settings: settings)
        persistence.syncSaveError = AppStatePersistenceError.writeDenied
        let (app, store, _) = makeAppState(settings: settings, secrets: secrets, persistence: persistence)

        app.removeSavedAccount(gmail)

        XCTAssertNotNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts, [gmail, att])
        XCTAssertEqual(store.loadSettings().savedAccounts, [gmail, att])
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "legacy-gmail-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: att.email)), "att-pw")
    }

    func testRemoveActiveAccountRollsBackWhenSettingsSaveFails() {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: gmail.email,
            mailHost: gmail.host,
            mailPort: gmail.port,
            savedAccounts: [gmail]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail.email): "gmail-pw"
        ])
        let persistence = AppStateMemoryPersistence(settings: settings)
        persistence.syncSaveError = AppStatePersistenceError.writeDenied
        let (app, store, _) = makeAppState(secrets: secrets, persistence: persistence)

        app.removeSavedAccount(gmail)

        XCTAssertNotNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts, [gmail])
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, gmail.email)
        XCTAssertEqual(app.mailHost, gmail.host)
        XCTAssertEqual(app.mailPort, gmail.port)
        XCTAssertEqual(app.mailAppPassword, "gmail-pw")
        XCTAssertEqual(store.loadSettings().mailEmail, gmail.email)
        XCTAssertEqual(store.loadSettings().savedAccounts, [gmail])
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: gmail.email)), "gmail-pw")
    }

    func testRemoveSavedAccountIsBlockedWhileConnectionVerificationIsRunning() {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let att = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: att.email,
            mailHost: att.host,
            mailPort: att.port,
            savedAccounts: [gmail, att]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail.email): "gmail-pw",
            .mailAppPassword(email: att.email): "att-pw"
        ])
        let (app, store, _) = makeAppState(settings: settings, secrets: secrets)
        app.isConnecting = true

        app.removeSavedAccount(gmail)

        XCTAssertNotNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts, [gmail, att])
        XCTAssertEqual(store.loadSettings().savedAccounts, [gmail, att])
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: gmail.email)), "gmail-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: att.email)), "att-pw")
    }

    // MARK: - Persistence across relaunch

    func testActiveAccountPersistsAcrossRelaunch() async {
        let secrets = InMemorySecretStore()
        let persistence = AppStateMemoryPersistence()
        let (app, _, _) = makeAppState(secrets: secrets, persistence: persistence)
        await connect(app, email: "me@gmail.com", host: "imap.gmail.com", password: "gmail-pw")
        await connect(app, email: "me@att.net", host: "imap.mail.att.net", password: "att-pw")

        // Fresh AppState over the same persistence + Keychain.
        let (relaunched, _, _) = makeAppState(secrets: secrets, persistence: persistence)

        XCTAssertEqual(relaunched.savedAccounts.map(\.email), ["me@gmail.com", "me@att.net"])
        XCTAssertTrue(relaunched.isAccountConnected)
        XCTAssertEqual(relaunched.mailEmail, "me@att.net")
        XCTAssertEqual(relaunched.mailAppPassword, "att-pw")
    }
}
