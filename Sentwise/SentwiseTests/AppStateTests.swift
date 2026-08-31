import SentwiseMail
import Security
import XCTest
@testable import Sentwise

@MainActor
final class AppStateTests: XCTestCase {

    private func makeAppState(
        provider: MailProvider,
        secrets: SecretStore = InMemorySecretStore(),
        persistence: AppStateMemoryPersistence = AppStateMemoryPersistence(),
        llm: LLMProviding = FakeLLMProvider(result: .success(()))
    ) -> AppState {
        AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: provider,
            llm: llm
        )
    }

    func testTestConnectionSuccessSavesPasswordAndConnects() async {
        let secrets = InMemorySecretStore()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "app-pw"

        await appState.testConnection()

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertFalse(appState.isConnecting)
        XCTAssertNil(appState.connectionError)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword(email: "me@gmail.com")), "app-pw")
        XCTAssertEqual(provider.lastCredentials?.email, "me@gmail.com")
    }

    func testTestConnectionSuccessClearsRecentMessagePreview() async {
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider)
        appState.recentMessages = [
            MailMessage(id: 1, from: MailAddress(email: "old@example.com"), subject: "Old", date: "")
        ]
        appState.fetchError = "Previous fetch failed"
        appState.mailEmail = "new@gmail.com"
        appState.mailAppPassword = "new-pw"

        await appState.testConnection()

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertTrue(appState.recentMessages.isEmpty)
        XCTAssertNil(appState.fetchError)
    }

    func testTestConnectionDoesNotConnectWhenPasswordSaveFails() async {
        let secrets = AppStateFailingSecretStore(seed: [.mailAppPassword: "old-pw"])
        secrets.failOnSet = .mailAppPassword(email: "me@gmail.com")
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "new-pw"

        await appState.testConnection()

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertFalse(appState.isConnecting)
        XCTAssertNil((try? secrets.value(for: .mailAppPassword(email: "me@gmail.com"))) ?? nil)
        XCTAssertEqual(provider.lastCredentials?.appPassword, "new-pw")
        XCTAssertEqual(
            appState.connectionError,
            "Couldn't save the app password in Keychain. Keychain returned status -25308."
        )
    }

    func testTestConnectionRestoresPreviousStateWhenSettingsSaveFails() async {
        let secrets = InMemorySecretStore(seed: [.mailAppPassword: "old-pw"])
        let provider = FakeAppMailProvider(result: .success(()))
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "old@gmail.com",
            mailHost: "imap.old.example.com",
            mailPort: 993
        ))
        persistence.syncSaveError = AppStatePersistenceError.writeDenied
        let appState = makeAppState(provider: provider, secrets: secrets, persistence: persistence)
        appState.mailEmail = "new@gmail.com"
        appState.mailAppPassword = "new-pw"
        appState.mailHost = "imap.new.example.com"
        appState.mailPort = 1993

        await appState.testConnection()

        let settings = persistence.loadSettings()
        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(appState.mailEmail, "old@gmail.com")
        XCTAssertEqual(appState.mailAppPassword, "old-pw")
        XCTAssertEqual(appState.mailHost, "imap.old.example.com")
        XCTAssertEqual(appState.mailPort, 993)
        XCTAssertEqual(settings.mailEmail, "old@gmail.com")
        XCTAssertEqual(settings.mailHost, "imap.old.example.com")
        XCTAssertEqual(settings.mailPort, 993)
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "old-pw")
        XCTAssertEqual(
            appState.connectionError,
            "Couldn't save mailbox settings. settings write denied"
        )
    }

    func testTestConnectionFailureSurfacesError() async {
        let provider = FakeAppMailProvider(result: .failure(.authenticationFailed("bad creds")))
        let appState = makeAppState(provider: provider)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "wrong"

        await appState.testConnection()

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNotNil(appState.connectionError)
    }

    func testTestConnectionRequiresCredentials() async {
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider)
        appState.mailEmail = ""
        appState.mailAppPassword = ""

        await appState.testConnection()

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil(provider.lastCredentials, "provider must not be called with incomplete credentials")
        XCTAssertNotNil(appState.connectionError)
    }

    func testPreviewRecentMessagesPopulatesResults() async {
        let messages = [
            MailMessage(id: 2, from: MailAddress(name: "Bob", email: "bob@x.com"), subject: "Hi", date: "")
        ]
        let provider = FakeAppMailProvider(result: .success(()), fetchResult: .success(messages))
        let appState = makeAppState(provider: provider)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "pw"

        await appState.previewRecentMessages()

        XCTAssertEqual(appState.recentMessages, messages)
        XCTAssertNil(appState.fetchError)
        XCTAssertFalse(appState.isFetching)
    }

    func testPreviewRecentMessagesSurfacesError() async {
        let provider = FakeAppMailProvider(result: .success(()), fetchResult: .failure(.commandFailed("SELECT failed")))
        let appState = makeAppState(provider: provider)
        appState.recentMessages = [
            MailMessage(id: 1, from: MailAddress(email: "old@example.com"), subject: "Old", date: "")
        ]
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "pw"

        await appState.previewRecentMessages()

        XCTAssertTrue(appState.recentMessages.isEmpty)
        XCTAssertNotNil(appState.fetchError)
    }

    func testPreviewBodyPopulatesReadableText() async {
        let raw = "--BOUND\r\nContent-Type: text/plain\r\n\r\nHello there.\r\n--BOUND--"
        let provider = FakeAppMailProvider(result: .success(()), bodyResult: .success(Data(raw.utf8)))
        let appState = makeAppState(provider: provider)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "pw"
        let message = MailMessage(id: 42, uidValidity: 99, from: MailAddress(email: "a@x.com"), subject: "Hi", date: "")

        let preview = await appState.previewBody(for: message)

        XCTAssertEqual(provider.lastBodyUID, 42)
        XCTAssertEqual(provider.lastExpectedUIDValidity, 99)
        XCTAssertEqual(preview?.id, 42)
        XCTAssertEqual(preview?.subject, "Hi")
        XCTAssertEqual(preview?.text, "Hello there.")
        XCTAssertEqual(appState.openedBody?.id, 42)
        XCTAssertEqual(appState.openedBody?.subject, "Hi")
        XCTAssertEqual(appState.openedBody?.text, "Hello there.")
        XCTAssertNil(appState.bodyError)
        XCTAssertFalse(appState.isFetchingBody)
    }

    func testPreviewBodySurfacesError() async {
        let provider = FakeAppMailProvider(result: .success(()), bodyResult: .failure(.commandFailed("FETCH failed")))
        let appState = makeAppState(provider: provider)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "pw"
        let message = MailMessage(id: 7, from: nil, subject: "X", date: "")

        let preview = await appState.previewBody(for: message)

        XCTAssertNil(preview)
        XCTAssertNil(appState.openedBody)
        XCTAssertNotNil(appState.bodyError)
        XCTAssertFalse(appState.isFetchingBody)
    }

    func testPreviewBodyIgnoresResultAfterAccountChanges() async {
        let provider = SuspendedFetchMailProvider()
        let appState = makeAppState(provider: provider)
        appState.mailEmail = "old@gmail.com"
        appState.mailAppPassword = "old-pw"
        let message = MailMessage(id: 7, from: nil, subject: "Old body", date: "")

        let previewTask = Task { await appState.previewBody(for: message) }
        await fulfillment(of: [provider.didStartBodyFetch], timeout: 1)

        appState.mailEmail = "new@gmail.com"
        appState.mailAppPassword = "new-pw"
        await appState.testConnection()

        provider.completeBodyFetch(with: .success(Data("Body from old account".utf8)))
        await previewTask.value

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertNil(appState.openedBody)
        XCTAssertNil(appState.bodyError)
        XCTAssertFalse(appState.isFetchingBody)
    }

    func testPreviewBodyIgnoresErrorAfterDisconnect() async {
        let provider = SuspendedFetchMailProvider()
        let appState = makeAppState(provider: provider)
        appState.mailEmail = "old@gmail.com"
        appState.mailAppPassword = "old-pw"
        let message = MailMessage(id: 8, from: nil, subject: "Old body", date: "")

        let previewTask = Task { await appState.previewBody(for: message) }
        await fulfillment(of: [provider.didStartBodyFetch], timeout: 1)

        appState.disconnectMail()

        provider.completeBodyFetch(with: .failure(MailError.commandFailed("FETCH failed")))
        await previewTask.value

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil(appState.openedBody)
        XCTAssertNil(appState.bodyError)
        XCTAssertFalse(appState.isFetchingBody)
    }

    func testPreviewBodyIgnoresResultAfterMessageListRefresh() async {
        let provider = SuspendedFetchMailProvider()
        let appState = makeAppState(provider: provider)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "pw"
        let message = MailMessage(id: 9, from: nil, subject: "Stale body", date: "")

        let bodyTask = Task { await appState.previewBody(for: message) }
        await fulfillment(of: [provider.didStartBodyFetch], timeout: 1)

        let refreshTask = Task { await appState.previewRecentMessages() }
        await fulfillment(of: [provider.didStartFetch], timeout: 1)

        provider.completeBodyFetch(with: .success(Data("Body from refreshed-away row".utf8)))
        await bodyTask.value

        XCTAssertNil(appState.openedBody)
        XCTAssertNil(appState.bodyError)
        XCTAssertTrue(appState.isFetching)

        provider.completeFetch(with: .success([]))
        await refreshTask.value

        XCTAssertTrue(appState.recentMessages.isEmpty)
        XCTAssertNil(appState.fetchError)
        XCTAssertFalse(appState.isFetching)
        XCTAssertFalse(appState.isFetchingBody)
    }

    func testPreviewRecentMessagesIgnoresResultAfterAccountChanges() async {
        let provider = SuspendedFetchMailProvider()
        let appState = makeAppState(provider: provider)
        appState.mailEmail = "old@gmail.com"
        appState.mailAppPassword = "old-pw"

        let previewTask = Task { await appState.previewRecentMessages() }
        await fulfillment(of: [provider.didStartFetch], timeout: 1)

        appState.mailEmail = "new@gmail.com"
        appState.mailAppPassword = "new-pw"
        await appState.testConnection()

        provider.completeFetch(with: .success([
            MailMessage(id: 1, from: MailAddress(email: "old@example.com"), subject: "Old", date: "")
        ]))
        await previewTask.value

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertTrue(appState.recentMessages.isEmpty)
        XCTAssertNil(appState.fetchError)
        XCTAssertFalse(appState.isFetching)
    }

    func testDisconnectClearsStoredPassword() async {
        let secrets = InMemorySecretStore()
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)
        appState.mailEmail = "me@gmail.com"
        appState.mailAppPassword = "app-pw"
        await appState.testConnection()
        appState.recentMessages = [
            MailMessage(id: 1, from: MailAddress(email: "me@example.com"), subject: "Hi", date: "")
        ]
        appState.fetchError = "Previous fetch failed"

        appState.disconnectMail()

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil((try? secrets.value(for: .mailAppPassword)) ?? nil)
        XCTAssertEqual(appState.mailAppPassword, "")
        XCTAssertTrue(appState.recentMessages.isEmpty)
        XCTAssertNil(appState.fetchError)
    }

    func testDisconnectKeepsConnectedStateWhenPasswordRemoveFails() {
        let secrets = AppStateFailingSecretStore(seed: [.mailAppPassword: "app-pw"])
        secrets.failOnRemove = .mailAppPassword
        let provider = FakeAppMailProvider(result: .success(()))
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com"
        ))
        let appState = makeAppState(provider: provider, secrets: secrets, persistence: persistence)

        appState.disconnectMail()

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertEqual(appState.mailAppPassword, "app-pw")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "app-pw")
        XCTAssertEqual(
            appState.connectionError,
            "Couldn't remove the app password in Keychain. Keychain returned status -25308."
        )
    }

    func testInitializationRemovesLegacyOAuthCredentials() {
        let secrets = InMemorySecretStore(seed: [
            .gmailToken: "legacy-token",
            .googleClientID: "legacy-client-id",
            .googleClientSecret: "legacy-client-secret"
        ])
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil((try? secrets.value(for: .gmailToken)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .googleClientID)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .googleClientSecret)) ?? nil)
        XCTAssertNil(appState.connectionError)
    }

    func testInitializationRemovesLegacyOAuthCredentialsWithoutToken() {
        let secrets = InMemorySecretStore(seed: [
            .googleClientID: "legacy-client-id",
            .googleClientSecret: "legacy-client-secret"
        ])
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil((try? secrets.value(for: .googleClientID)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .googleClientSecret)) ?? nil)
        XCTAssertNil(appState.connectionError)
    }

    func testInitializationSurfacesLegacyOAuthCredentialRemoveFailure() {
        let secrets = AppStateFailingSecretStore(seed: [
            .gmailToken: "legacy-token",
            .googleClientID: "legacy-client-id",
            .googleClientSecret: "legacy-client-secret"
        ])
        secrets.failOnRemove = .googleClientSecret
        let provider = FakeAppMailProvider(result: .success(()))
        let appState = makeAppState(provider: provider, secrets: secrets)

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil((try? secrets.value(for: .gmailToken)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .googleClientID)) ?? nil)
        XCTAssertEqual(try? secrets.value(for: .googleClientSecret), "legacy-client-secret")
        XCTAssertEqual(
            appState.connectionError,
            "Couldn't remove the legacy Gmail OAuth credentials from Keychain. Keychain returned status -25308."
        )
    }

    func testDisconnectClearsLegacyOAuthCredentials() {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword: "app-pw"
        ])
        let provider = FakeAppMailProvider(result: .success(()))
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com"
        ))
        let appState = makeAppState(provider: provider, secrets: secrets, persistence: persistence)

        XCTAssertTrue(appState.isAccountConnected)
        try? secrets.set("legacy-token", for: .gmailToken)
        try? secrets.set("legacy-client-id", for: .googleClientID)
        try? secrets.set("legacy-client-secret", for: .googleClientSecret)

        appState.disconnectMail()

        XCTAssertFalse(appState.isAccountConnected)
        XCTAssertNil((try? secrets.value(for: .gmailToken)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .googleClientID)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .googleClientSecret)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .mailAppPassword)) ?? nil)
    }

    func testDisconnectKeepsConnectedStateWhenLegacyOAuthCredentialRemoveFails() {
        let secrets = AppStateFailingSecretStore(seed: [
            .mailAppPassword: "app-pw"
        ])
        let provider = FakeAppMailProvider(result: .success(()))
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com"
        ))
        let appState = makeAppState(provider: provider, secrets: secrets, persistence: persistence)
        try? secrets.set("legacy-token", for: .gmailToken)
        try? secrets.set("legacy-client-id", for: .googleClientID)
        try? secrets.set("legacy-client-secret", for: .googleClientSecret)
        secrets.failOnRemove = .googleClientSecret

        appState.disconnectMail()

        XCTAssertTrue(appState.isAccountConnected)
        XCTAssertNil((try? secrets.value(for: .gmailToken)) ?? nil)
        XCTAssertNil((try? secrets.value(for: .googleClientID)) ?? nil)
        XCTAssertEqual(try? secrets.value(for: .googleClientSecret), "legacy-client-secret")
        XCTAssertEqual(try? secrets.value(for: .mailAppPassword), "app-pw")
        XCTAssertEqual(
            appState.connectionError,
            "Couldn't remove the legacy Gmail OAuth credentials from Keychain. Keychain returned status -25308."
        )
    }
}
