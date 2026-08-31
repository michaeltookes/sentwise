import SentwiseMail
import XCTest
@testable import Sentwise

@MainActor
final class AppStateAccountReviewFeedbackTests: XCTestCase {

    private func makeAppState(
        settings: Settings,
        secrets: SecretStore,
        provider: MailProvider = FakeAppMailProvider(result: .success(()))
    ) -> (AppState, AppStateMemoryPersistence) {
        let persistence = AppStateMemoryPersistence(settings: settings)
        let app = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: FakeLLMProvider(result: .success(()))
        )
        return (app, persistence)
    }

    func testSwitchFailureRestartsWatcherOnOutgoingAccount() async {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let att = SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: att.email,
            mailHost: att.host,
            mailPort: att.port,
            savedAccounts: [gmail, att],
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail.email): "expired-gmail-pw",
            .mailAppPassword(email: att.email): "att-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let provider = FakeAppMailProvider(result: .failure(.authenticationFailed("expired password")))
        let (app, persistence) = makeAppState(settings: settings, secrets: secrets, provider: provider)
        app.watchStatus = .watching

        await app.switchToSavedAccount(gmail)

        XCTAssertEqual(app.mailEmail, att.email)
        XCTAssertEqual(app.mailAppPassword, "att-pw")
        XCTAssertEqual(app.watchStatus, .watching)
        XCTAssertTrue(persistence.processedMessages.hasBaselineStart(account: att.email, mailbox: .inbox))
        app.stopWatching()
    }

    func testPendingSwitchSettingsSaveKeepsOutgoingAccountUntilVerificationSucceeds() async {
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
        let provider = SuspendedAppMailProvider()
        let (app, persistence) = makeAppState(settings: settings, secrets: secrets, provider: provider)

        let switchTask = Task { await app.switchToSavedAccount(gmail) }
        await fulfillment(of: [provider.didStartVerification], timeout: 1)

        app.pollIntervalSeconds = 120
        app.saveSettingsSync()

        var savedSettings = persistence.loadSettings()
        XCTAssertEqual(savedSettings.mailEmail, att.email)
        XCTAssertEqual(savedSettings.mailHost, att.host)
        XCTAssertEqual(savedSettings.mailPort, att.port)
        XCTAssertEqual(savedSettings.pollIntervalSeconds, 120)

        provider.complete(with: .failure(MailError.authenticationFailed("expired password")))
        await switchTask.value

        savedSettings = persistence.loadSettings()
        XCTAssertNotNil(app.connectionError)
        XCTAssertEqual(app.mailEmail, att.email)
        XCTAssertEqual(app.mailAppPassword, "att-pw")
        XCTAssertEqual(savedSettings.mailEmail, att.email)
        XCTAssertEqual(savedSettings.mailHost, att.host)
        XCTAssertEqual(savedSettings.mailPort, att.port)
    }

    func testSwitchWithoutStoredSecretClearsStaleWorkspaceGuidance() async {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let orphan = SavedMailAccount(email: "ghost@att.net", host: "imap.mail.att.net", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: gmail.email,
            mailHost: gmail.host,
            mailPort: gmail.port,
            savedAccounts: [gmail, orphan]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: gmail.email): "gmail-pw"
        ])
        let (app, _) = makeAppState(settings: settings, secrets: secrets)
        app.isAccountConnected = true
        app.workspaceAuthFailure = .appPasswordRejectedWorkspace
        app.workspaceAuthIsCustomDomain = true
        XCTAssertNotNil(app.workspaceAuthGuidance)

        await app.switchToSavedAccount(orphan)

        XCTAssertEqual(app.workspaceAuthFailure, .none)
        XCTAssertNil(app.workspaceAuthGuidance)
        XCTAssertNotNil(app.connectionError)
        XCTAssertEqual(app.mailEmail, gmail.email)
    }

    func testDisconnectDuringPendingSwitchDoesNotRemoveOutgoingAccountCredentials() async {
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
        let provider = SuspendedAppMailProvider()
        let (app, _) = makeAppState(settings: settings, secrets: secrets, provider: provider)

        let switchTask = Task { await app.switchToSavedAccount(gmail) }
        await fulfillment(of: [provider.didStartVerification], timeout: 1)

        app.disconnectMail()

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, att.email)
        XCTAssertEqual(app.mailAppPassword, "att-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: att.email)), "att-pw")
        XCTAssertNil(app.connectionError)

        provider.complete(with: .success(()))
        await switchTask.value

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, gmail.email)
        XCTAssertEqual(app.mailAppPassword, "gmail-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: att.email)), "att-pw")
    }

    func testLegacyPasswordLookupNormalizesSavedAccountEmail() {
        let gmail = SavedMailAccount(email: "Me@Gmail.com", host: "imap.gmail.com", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: gmail.email,
            mailHost: gmail.host,
            mailPort: gmail.port,
            savedAccounts: [gmail]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "legacy-gmail-pw"
        ])
        let (app, _) = makeAppState(settings: settings, secrets: secrets)

        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailAppPassword, "legacy-gmail-pw")
        XCTAssertEqual(app.storedMailPassword(forEmail: "ME@GMAIL.COM"), "legacy-gmail-pw")
    }

    func testRemovingActiveCustomHostClearsHostGuidance() {
        let account = SavedMailAccount(email: "me@company.example", host: "imap.company.example", port: 1993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: account.email,
            mailHost: account.host,
            mailHostGuidanceEmail: account.email,
            mailPort: account.port,
            savedAccounts: [account]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account.email): "company-pw"
        ])
        let (app, persistence) = makeAppState(settings: settings, secrets: secrets)

        app.removeSavedAccount(account)

        let savedSettings = persistence.loadSettings()
        XCTAssertNil(app.connectionError)
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "")
        XCTAssertEqual(app.mailHost, Settings.default.mailHost)
        XCTAssertEqual(app.mailPort, Settings.default.mailPort)
        XCTAssertNil(app.buildSettings().mailHostGuidanceEmail)
        XCTAssertFalse(app.buildSettings().mailHostGuidancePendingEmail)
        XCTAssertEqual(savedSettings.mailEmail, "")
        XCTAssertEqual(savedSettings.mailHost, Settings.default.mailHost)
        XCTAssertEqual(savedSettings.mailPort, Settings.default.mailPort)
        XCTAssertNil(savedSettings.mailHostGuidanceEmail)
        XCTAssertFalse(savedSettings.mailHostGuidancePendingEmail)

        app.updateMailEmailFromUser("me@yahoo.com")

        XCTAssertEqual(app.mailHost, "imap.mail.yahoo.com")
    }

    func testRemovingDisconnectedCurrentAccountClearsFormAndHostGuidance() {
        let account = SavedMailAccount(email: "me@company.example", host: "imap.company.example", port: 1993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: account.email,
            mailHost: account.host,
            mailHostGuidanceEmail: account.email,
            mailHostGuidancePendingEmail: true,
            mailPort: account.port,
            savedAccounts: [account]
        )
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: account.email): "company-pw"
        ])
        let (app, persistence) = makeAppState(settings: settings, secrets: secrets)
        app.disconnectMail()

        app.removeSavedAccount(account)

        let savedSettings = persistence.loadSettings()
        XCTAssertNil(app.connectionError)
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "")
        XCTAssertEqual(app.mailHost, Settings.default.mailHost)
        XCTAssertEqual(app.mailPort, Settings.default.mailPort)
        XCTAssertNil(app.buildSettings().mailHostGuidanceEmail)
        XCTAssertFalse(app.buildSettings().mailHostGuidancePendingEmail)
        XCTAssertEqual(savedSettings.mailEmail, "")
        XCTAssertEqual(savedSettings.mailHost, Settings.default.mailHost)
        XCTAssertEqual(savedSettings.mailPort, Settings.default.mailPort)
        XCTAssertNil(savedSettings.mailHostGuidanceEmail)
        XCTAssertFalse(savedSettings.mailHostGuidancePendingEmail)
        XCTAssertEqual(app.savedAccounts, [])
    }

    func testRemoveActivePerAccountKeepsInactiveLegacyPassword() {
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
        let (app, persistence) = makeAppState(settings: settings, secrets: secrets)

        app.removeSavedAccount(att)

        XCTAssertNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts, [gmail])
        XCTAssertEqual(persistence.loadSettings().savedAccounts, [gmail])
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.mailEmail, "")
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: att.email))) ?? nil)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "legacy-gmail-pw")
    }

    func testDisconnectPreservesInactiveLegacyPasswordWhenActiveHasPerAccountSecret() {
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
        let (app, _) = makeAppState(settings: settings, secrets: secrets)

        app.disconnectMail()

        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.mailAppPassword, "")
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: att.email))) ?? nil)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "legacy-gmail-pw")
    }

    func testDisconnectOriginalMigratedAccountRemovesDuplicateLegacyPassword() {
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
            .mailAppPassword: "legacy-gmail-pw",
            .mailAppPassword(email: gmail.email): "gmail-pw"
        ])
        let (app, _) = makeAppState(settings: settings, secrets: secrets)

        app.disconnectMail()

        XCTAssertNil(app.connectionError)
        XCTAssertFalse(app.isAccountConnected)
        XCTAssertEqual(app.mailAppPassword, "")
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: gmail.email))) ?? nil)
        XCTAssertNil((try? secrets.value(for: .mailAppPassword)) ?? nil)
    }

    func testRemoveOriginalMigratedAccountRemovesDuplicateLegacyPassword() {
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
            .mailAppPassword(email: gmail.email): "gmail-pw",
            .mailAppPassword(email: att.email): "att-pw"
        ])
        let (app, persistence) = makeAppState(settings: settings, secrets: secrets)

        app.removeSavedAccount(gmail)

        XCTAssertNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts, [att])
        XCTAssertEqual(persistence.loadSettings().savedAccounts, [att])
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: gmail.email))) ?? nil)
        XCTAssertNil((try? secrets.value(for: .mailAppPassword)) ?? nil)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: att.email)), "att-pw")
    }

    func testRemovingDisconnectedAccountWithoutPerAccountKeyPreservesLegacyOwnerPassword() {
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
            .mailAppPassword: "legacy-gmail-pw"
        ])
        let (app, persistence) = makeAppState(settings: settings, secrets: secrets)

        app.removeSavedAccount(att)

        XCTAssertNil(app.connectionError)
        XCTAssertEqual(app.savedAccounts, [gmail])
        XCTAssertEqual(persistence.loadSettings().savedAccounts, [gmail])
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: att.email))) ?? nil)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "legacy-gmail-pw")
        XCTAssertEqual(app.storedMailPassword(forEmail: gmail.email), "legacy-gmail-pw")
        XCTAssertNil(app.storedMailPassword(forEmail: att.email))
    }

    func testDisconnectKeepsLegacyPasswordWhenEmptyPerAccountRemovalFails() {
        let gmail = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: gmail.email,
            mailHost: gmail.host,
            mailPort: gmail.port,
            savedAccounts: [gmail]
        )
        let secrets = AppStateFailingSecretStore(seed: [
            .mailAppPassword: "legacy-gmail-pw",
            .mailAppPassword(email: gmail.email): ""
        ])
        secrets.failOnRemove = .mailAppPassword(email: gmail.email)
        let (app, _) = makeAppState(settings: settings, secrets: secrets)

        app.disconnectMail()

        XCTAssertNotNil(app.connectionError)
        XCTAssertTrue(app.isAccountConnected)
        XCTAssertEqual(app.mailAppPassword, "legacy-gmail-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "legacy-gmail-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: gmail.email)), "")
    }
}
