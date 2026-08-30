import XCTest
import SentwiseMail
@testable import Sentwise

@MainActor
/// AppState-level behavior of the managed provider: sign-in/sign-out publishing and
/// auth-failure reconciliation during drafting.
final class ManagedProviderAppStateTests: XCTestCase {
    func testManagedSignInStoresPendingFlowEmailWhenInputChangesBeforeVerify() async throws {
        let secrets = InMemorySecretStore()
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed"
        ))
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: ManagedProviderQueueClerkTransport([
                managedProviderClerkResponse(
                    #"{"response":{"id":"sia_1","supported_first_factors":[{"strategy":"email_code","email_address_id":"ema_1"}]}}"#,
                    clientToken: "client_A"
                ),
                managedProviderClerkResponse(#"{"response":{"id":"sia_1"}}"#, clientToken: "client_B"),
                managedProviderClerkResponse(
                    #"{"response":{"id":"sia_1","status":"complete","created_session_id":"sess_1"}}"#,
                    clientToken: "client_C"
                ),
                managedProviderClerkResponse(#"{"jwt":"session.jwt"}"#, clientToken: "client_D")
            ])
        )
        let managedAccount = ManagedAccountService(secrets: secrets, clerk: clerk)
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(())),
            managedAccount: managedAccount
        )

        appState.managedEmailInput = "marcus@example.com"
        await appState.startManagedSignIn()

        appState.managedEmailInput = "wrong@example.com"
        appState.managedCodeInput = "123456"
        await appState.verifyManagedCode()

        XCTAssertEqual(appState.managedAccountEmail, "marcus@example.com")
        XCTAssertEqual(appState.managedEmailInput, "marcus@example.com")
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountID, "clerk-session:sess_1")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_D")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_1")
    }

    func testSignOutManagedKeepsPublishedStateWhenKeychainRemovalFails() async throws {
        let secrets = ManagedProviderFailingRemoveSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)

        await appState.signOutManaged()

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountEmail, "marcus@example.com")
        XCTAssertNotNil(appState.managedError)
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testSignOutManagedClearsPublishedStateWhenCredentialRemovalIsPartial() async throws {
        let secrets = ManagedProviderFailingRemoveSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedSessionID]
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)

        await appState.signOutManaged()

        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountEmail, "")
        XCTAssertEqual(appState.managedAccountID, "")
        XCTAssertEqual(appState.verifiedLLMModel, "")
        XCTAssertNotNil(appState.managedError)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
    }

    func testManagedAuthInvalidationDuringDraftClearsPublishedAccountState() async throws {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: "me@gmail.com"): "app-pw",
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: ManagedProviderQueueClerkTransport([
                managedProviderClerkResponse(#"{"errors":[{"message":"expired"}]}"#, status: 401)
            ])
        )
        let managedAccount = ManagedAccountService(secrets: secrets, clerk: clerk)
        let llm = LLMService(
            transport: FakeLLMTransport(response: HTTPResponse(
                statusCode: 200,
                body: Data(#"{"text":"ok"}"#.utf8)
            )),
            managedSessionProvider: managedAccount
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(
                result: .success(()),
                bodyResult: .success(Data("Are you free Thursday?".utf8))
            ),
            llm: llm,
            managedAccount: managedAccount
        )

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)

        let draft = await appState.generateDraft(for: MailMessage(
            id: 5,
            from: MailAddress(name: "Alice", email: "alice@example.com"),
            subject: "Lunch?",
            date: ""
        ))

        XCTAssertNil(draft)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountEmail, "")
        XCTAssertEqual(appState.verifiedLLMModel, "")
        XCTAssertEqual(appState.draftError, "Sign in to Sentwise AI first (Settings → AI).")
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testManagedProxyAuthFailureDuringDraftClearsPublishedAccountState() async throws {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: "me@gmail.com"): "app-pw",
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: ManagedProviderQueueClerkTransport([
                managedProviderClerkResponse(#"{"jwt":"live.jwt"}"#, clientToken: "client_Y")
            ])
        )
        let managedAccount = ManagedAccountService(secrets: secrets, clerk: clerk)
        let llm = LLMService(
            transport: FakeLLMTransport(response: HTTPResponse(
                statusCode: 401,
                body: Data(#"{"error":{"type":"unauthenticated","message":"Sign in."}}"#.utf8)
            )),
            managedSessionProvider: managedAccount
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(
                result: .success(()),
                bodyResult: .success(Data("Are you free Thursday?".utf8))
            ),
            llm: llm,
            managedAccount: managedAccount
        )

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)

        let draft = await appState.generateDraft(for: MailMessage(
            id: 5,
            from: MailAddress(name: "Alice", email: "alice@example.com"),
            subject: "Lunch?",
            date: ""
        ))

        XCTAssertNil(draft)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountEmail, "")
        XCTAssertEqual(appState.verifiedLLMModel, "")
        XCTAssertEqual(appState.draftError, "Sign in to Sentwise AI first (Settings → AI).")
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }

    func testLaunchDoesNotRestoreInvalidatedManagedCredentialsAfterCleanupFailure() async throws {
        let secrets = ManagedAccountFailingSecretStore(seed: [
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X"
        ])
        secrets.failOnRemoveKeys = [.managedClientToken, .managedSessionID]
        let invalidatingAccount = ManagedAccountService(secrets: secrets)

        await invalidatingAccount.invalidateSession()

        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )

        XCTAssertEqual(try secrets.value(for: .managedCredentialsInvalidated), "1")
        XCTAssertEqual(try secrets.value(for: .managedClientToken), "client_X")
        XCTAssertEqual(try secrets.value(for: .managedSessionID), "sess_X")
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertFalse(appState.isLLMConnected)
        XCTAssertEqual(appState.managedAccountEmail, "")
    }

    func testManagedProxyAuthFailureFromStaleDraftStillClearsPublishedAccountState() async throws {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: "me@gmail.com"): "app-pw",
            .managedClientToken: "client_X",
            .managedSessionID: "sess_X",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let persistence = AppStateMemoryPersistence(settings: Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            llmProvider: "managed",
            llmVerifiedModel: LLMProviderKind.managed.defaultModel,
            managedAccountEmail: "marcus@example.com"
        ))
        let clerk = ClerkClient(
            frontendAPIBaseURL: URL(string: "https://peaceful-eel-9660.clerk.accounts.dev")!,
            transport: ManagedProviderQueueClerkTransport([
                managedProviderClerkResponse(#"{"jwt":"live.jwt"}"#, clientToken: "client_Y")
            ])
        )
        let managedAccount = ManagedAccountService(secrets: secrets, clerk: clerk)
        let transport = ManagedProviderSuspendedLLMTransport()
        let llm = LLMService(
            transport: transport,
            managedSessionProvider: managedAccount
        )
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(
                result: .success(()),
                bodyResult: .success(Data("Are you free Thursday?".utf8))
            ),
            llm: llm,
            managedAccount: managedAccount
        )

        XCTAssertTrue(appState.isManagedSignedIn)
        XCTAssertTrue(appState.isLLMConnected)

        let draftTask = Task {
            await appState.generateDraft(for: MailMessage(
                id: 5,
                from: MailAddress(name: "Alice", email: "alice@example.com"),
                subject: "Lunch?",
                date: ""
            ))
        }
        await fulfillment(of: [transport.didStartRequest], timeout: 1.0)

        appState.selectLLMProvider(.anthropic)
        transport.complete(with: .success(HTTPResponse(
            statusCode: 401,
            body: Data(#"{"error":{"type":"unauthenticated","message":"Sign in."}}"#.utf8)
        )))
        let draft = await draftTask.value

        XCTAssertNil(draft)
        XCTAssertEqual(appState.llmProviderKind, .anthropic)
        XCTAssertFalse(appState.isManagedSignedIn)
        XCTAssertEqual(appState.managedAccountEmail, "")
        XCTAssertNil(appState.draftError)
        XCTAssertNil(try secrets.value(for: .managedClientToken))
        XCTAssertNil(try secrets.value(for: .managedSessionID))
    }
}
