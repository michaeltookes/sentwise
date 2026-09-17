import SentwiseMail
import XCTest
@testable import Sentwise

/// Per-account voice profiles (item 99): voice is learned and resolved per
/// account, drafts for account A never borrow account B's voice, the legacy
/// single profile migrates to the connected account, and a per-account purge
/// leaves other accounts' voice intact.
@MainActor
final class AppStateMultiAccountVoiceTests: XCTestCase {

    private let accountA = "marcus@work.com"
    private let accountB = "marcus@side.com"

    private func profile(summary: String, greeting: String = "Hi,") -> VoiceProfile {
        VoiceProfile(
            greeting: greeting, signOff: "Best,", formality: "casual", tone: "warm",
            averageLength: "short", commonPhrases: [], summary: summary,
            sampleCount: 5, generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeAppState(persistence: AppStateMemoryPersistence, mailEmail: String) -> AppState {
        let secrets = InMemorySecretStore(seed: [
            .mailAppPassword(email: mailEmail): "app-pw",
            .llmAPIKey(provider: "anthropic"): "sk-live"
        ])
        let appState = AppState(
            persistence: persistence,
            secrets: secrets,
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        return appState
    }

    private func settings(mailEmail: String, schemaVersion: Int = Settings.currentSchemaVersion) -> Settings {
        Settings(
            schemaVersion: schemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: mailEmail,
            llmProvider: "anthropic",
            llmVerifiedModel: "claude-sonnet-4-6"
        )
    }

    func testVoiceProfileResolvedPerAccount() {
        let store = AppStateMemoryPersistence(settings: settings(mailEmail: accountA))
        store.saveVoiceProfile(profile(summary: "Voice A"), accountKey: accountA)
        store.saveVoiceProfile(profile(summary: "Voice B"), accountKey: accountB)

        let appState = makeAppState(persistence: store, mailEmail: accountA)

        // Focused account publishes its own voice; each account resolves its own.
        XCTAssertEqual(appState.voiceProfile?.summary, "Voice A")
        XCTAssertEqual(appState.voiceProfile(forAccountEmail: accountA)?.summary, "Voice A")
        XCTAssertEqual(appState.voiceProfile(forAccountEmail: accountB)?.summary, "Voice B")
        // Casing/whitespace differences resolve to the same account.
        XCTAssertEqual(appState.voiceProfile(forAccountEmail: " Marcus@Side.com ")?.summary, "Voice B")
    }

    func testFocusedAccountWithoutVoiceDoesNotBorrowAnother() {
        let store = AppStateMemoryPersistence(settings: settings(mailEmail: accountA))
        store.saveVoiceProfile(profile(summary: "Voice B"), accountKey: accountB)

        let appState = makeAppState(persistence: store, mailEmail: accountA)

        XCTAssertNil(appState.voiceProfile)
        XCTAssertNil(appState.voiceProfile(forAccountEmail: accountA))
        XCTAssertEqual(appState.voiceProfile(forAccountEmail: accountB)?.summary, "Voice B")
    }

    func testVoiceLookupUsesPublishedProfileOwnerNotLiveFormEmail() {
        let store = AppStateMemoryPersistence(settings: settings(mailEmail: accountA))
        store.saveVoiceProfile(profile(summary: "Voice A"), accountKey: accountA)
        store.saveVoiceProfile(profile(summary: "Voice B"), accountKey: accountB)
        let appState = makeAppState(persistence: store, mailEmail: accountA)

        appState.disconnectMail()
        appState.mailEmail = accountB

        XCTAssertEqual(appState.voiceProfile?.summary, "Voice A")
        XCTAssertEqual(appState.voiceProfile(forAccountEmail: accountB)?.summary, "Voice B")
    }

    func testForgetVoiceProfileRemovesPublishedProfileOwnerNotLiveFormEmail() {
        let store = AppStateMemoryPersistence(settings: settings(mailEmail: accountA))
        store.saveVoiceProfile(profile(summary: "Voice A"), accountKey: accountA)
        store.saveVoiceProfile(profile(summary: "Voice B"), accountKey: accountB)
        let appState = makeAppState(persistence: store, mailEmail: accountA)

        appState.disconnectMail()
        appState.mailEmail = accountB
        appState.forgetVoiceProfile()

        XCTAssertNil(appState.voiceProfile)
        XCTAssertNil(store.loadVoiceProfile(accountKey: accountA))
        XCTAssertEqual(store.loadVoiceProfile(accountKey: accountB)?.summary, "Voice B")
    }

    func testPublishedVoiceReloadsWhenFocusedAccountChanges() throws {
        let store = AppStateMemoryPersistence(settings: settings(mailEmail: accountA))
        store.saveVoiceProfile(profile(summary: "Voice A"), accountKey: accountA)
        store.saveVoiceProfile(profile(summary: "Voice B"), accountKey: accountB)
        let appState = makeAppState(persistence: store, mailEmail: accountA)

        XCTAssertEqual(appState.voiceProfile?.summary, "Voice A")

        try appState.persistVerifiedConnection(
            MailAccountCredentials(
                email: accountB,
                appPassword: "side-pw",
                host: "imap.side.com",
                port: 993
            ),
            clearSignature: true
        )

        XCTAssertEqual(appState.mailEmail, accountB)
        XCTAssertEqual(appState.voiceProfile?.summary, "Voice B")
        XCTAssertEqual(appState.voiceProfile(forAccountEmail: accountB)?.summary, "Voice B")
    }

    func testLegacyVoiceMigratesToConnectedAccountOnLaunch() {
        // A pre-item-99 install: schema 20, one unscoped VoiceProfile.json, a
        // connected account.
        let store = AppStateMemoryPersistence(
            settings: settings(mailEmail: accountA, schemaVersion: Settings.byokParkedSchemaVersion),
            voiceProfile: profile(summary: "Legacy voice")
        )

        let appState = makeAppState(persistence: store, mailEmail: accountA)

        // The legacy profile is attributed to the connected account and the
        // unscoped slot is cleared.
        XCTAssertEqual(store.loadVoiceProfile(accountKey: accountA)?.summary, "Legacy voice")
        XCTAssertNil(store.voiceProfile)
        XCTAssertEqual(appState.voiceProfile?.summary, "Legacy voice")
        XCTAssertEqual(store.loadSettings().schemaVersion, Settings.currentSchemaVersion)
    }

    func testMigrationDoesNotOverwriteExistingPerAccountVoice() {
        let store = AppStateMemoryPersistence(
            settings: settings(mailEmail: accountA, schemaVersion: Settings.byokParkedSchemaVersion),
            voiceProfile: profile(summary: "Legacy voice")
        )
        store.saveVoiceProfile(profile(summary: "Existing A"), accountKey: accountA)

        _ = makeAppState(persistence: store, mailEmail: accountA)

        // The existing per-account profile wins; the legacy one is left untouched.
        XCTAssertEqual(store.loadVoiceProfile(accountKey: accountA)?.summary, "Existing A")
        XCTAssertEqual(store.voiceProfile?.summary, "Legacy voice")
    }

    func testPurgingOneAccountLeavesOtherAccountVoiceIntact() throws {
        let store = AppStateMemoryPersistence(settings: settings(mailEmail: accountA))
        store.saveVoiceProfile(profile(summary: "Voice A"), accountKey: accountA)
        store.saveVoiceProfile(profile(summary: "Voice B"), accountKey: accountB)

        // Purge account B while it is not the active account (unscoped preserved).
        try store.purgeAccountScopedArtifacts(for: accountB, includeUnscopedArtifacts: false)

        XCTAssertNil(store.loadVoiceProfile(accountKey: accountB))
        XCTAssertEqual(store.loadVoiceProfile(accountKey: accountA)?.summary, "Voice A")
    }

    func testActiveAccountPurgeRemovesItsVoiceAndLegacySlot() throws {
        let store = AppStateMemoryPersistence(
            settings: settings(mailEmail: accountA),
            voiceProfile: profile(summary: "Legacy voice")
        )
        store.saveVoiceProfile(profile(summary: "Voice A"), accountKey: accountA)
        store.saveVoiceProfile(profile(summary: "Voice B"), accountKey: accountB)

        try store.purgeAccountScopedArtifacts(for: accountA, includeUnscopedArtifacts: true)

        XCTAssertNil(store.loadVoiceProfile(accountKey: accountA))
        XCTAssertNil(store.voiceProfile)
        XCTAssertEqual(store.loadVoiceProfile(accountKey: accountB)?.summary, "Voice B")
    }

    func testRemoveAllVoiceProfilesClearsEveryAccount() throws {
        let store = AppStateMemoryPersistence(
            settings: settings(mailEmail: accountA),
            voiceProfile: profile(summary: "Legacy voice")
        )
        store.saveVoiceProfile(profile(summary: "Voice A"), accountKey: accountA)
        store.saveVoiceProfile(profile(summary: "Voice B"), accountKey: accountB)

        try store.removeAllVoiceProfiles()

        XCTAssertNil(store.voiceProfile)
        XCTAssertNil(store.loadVoiceProfile(accountKey: accountA))
        XCTAssertNil(store.loadVoiceProfile(accountKey: accountB))
    }
}
