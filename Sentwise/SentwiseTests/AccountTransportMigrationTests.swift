import SentwiseMail
import XCTest
@testable import Sentwise

/// Schema 24 (item 31 T31-6): per-account transport fields on `SavedMailAccount`.
/// Old records load with defaults; Google accounts are back-filled with
/// `authProvider = "google"`; Microsoft-shaped records round-trip.
@MainActor
final class AccountTransportMigrationTests: XCTestCase {

    private func migrate(_ json: String, secrets: InMemorySecretStore = InMemorySecretStore()) throws -> Settings {
        let loaded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let persistence = AppStateMemoryPersistence(settings: loaded)
        return AppState.fullyMigratedSettings(loaded: loaded, secrets: secrets, persistence: persistence)
    }

    func testVersion23RecordLoadsWithTransportDefaultsAndGoogleIsBackfilled() throws {
        let secrets = InMemorySecretStore()
        try secrets.set(GoogleMailCredential.marker, for: .mailAppPassword(email: "me@gmail.com"))
        try secrets.set("abcd efgh ijkl mnop", for: .mailAppPassword(email: "pw@example.com"))
        let json = """
        {"schemaVersion":23,"mailEmail":"me@gmail.com",
         "savedAccounts":[
           {"email":"me@gmail.com","host":"imap.gmail.com","port":993},
           {"email":"pw@example.com","host":"imap.example.com","port":993},
           {"email":"gone@example.com","host":"imap.example.com","port":993}]}
        """
        let migrated = try migrate(json, secrets: secrets)

        XCTAssertEqual(migrated.schemaVersion, Settings.accountTransportSchemaVersion)
        let google = try XCTUnwrap(migrated.savedAccounts.first { $0.email == "me@gmail.com" })
        XCTAssertEqual(google.authProvider, "google")
        XCTAssertNil(google.smtpHost, "existing accounts keep the provider-default transport")
        XCTAssertNil(google.smtpPort)
        XCTAssertNil(google.smtpSecurity, "nil means implicit TLS")
        let password = try XCTUnwrap(migrated.savedAccounts.first { $0.email == "pw@example.com" })
        XCTAssertEqual(password.authProvider, "password")
        let unknown = try XCTUnwrap(migrated.savedAccounts.first { $0.email == "gone@example.com" })
        XCTAssertNil(unknown.authProvider, "an unreadable slot is not guessed")
    }

    func testPre11FileMigratesThroughTheWholeChainToCurrent() throws {
        let json = """
        {"schemaVersion":10,"mailEmail":"old@gmail.com","mailHost":"imap.gmail.com","mailPort":993}
        """
        let migrated = try migrate(json)
        XCTAssertEqual(migrated.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(Settings.currentSchemaVersion, 24)
    }

    func testAlreadyCurrentFileIsLeftAlone() throws {
        let secrets = InMemorySecretStore()
        try secrets.set(GoogleMailCredential.marker, for: .mailAppPassword(email: "me@gmail.com"))
        let json = """
        {"schemaVersion":24,"savedAccounts":[{"email":"me@gmail.com","host":"imap.gmail.com","port":993}]}
        """
        let migrated = try migrate(json, secrets: secrets)
        XCTAssertNil(migrated.savedAccounts.first?.authProvider, "no migration re-runs at the current version")
    }

    func testMicrosoftAccountRoundTripsAndFieldsAreOmittedWhenNil() throws {
        let microsoft = SavedMailAccount(
            email: "me@outlook.com",
            host: "outlook.office365.com",
            port: 993,
            smtpHost: "smtp.office365.com",
            smtpPort: 587,
            smtpSecurity: SavedMailAccount.smtpSecuritySTARTTLS,
            authProvider: SavedMailAccount.authProviderMicrosoft
        )
        let decoded = try JSONDecoder().decode(
            SavedMailAccount.self,
            from: try JSONEncoder().encode(microsoft)
        )
        XCTAssertEqual(decoded, microsoft)

        let legacy = SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993)
        let json = String(bytes: try JSONEncoder().encode(legacy), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("smtp"), "a Google record is byte-compatible with the pre-24 shape")
        XCTAssertFalse(json.contains("authProvider"))
    }

    func testDowngradeReadsNewFileIgnoringUnknownKeys() throws {
        // A pre-24 build decodes only the original three keys; the extra keys must
        // not break a decoder that does not know them (round trip back).
        struct Legacy: Codable { var email: String; var host: String; var port: Int }
        let microsoft = SavedMailAccount(
            email: "me@outlook.com", host: "outlook.office365.com", port: 993,
            smtpHost: "smtp.office365.com", smtpPort: 587, smtpSecurity: "starttls", authProvider: "microsoft"
        )
        let legacy = try JSONDecoder().decode(Legacy.self, from: try JSONEncoder().encode(microsoft))
        XCTAssertEqual(legacy.host, "outlook.office365.com")
    }

    func testUpsertKeepsTransportFieldsOfAnExistingAccount() {
        let microsoft = SavedMailAccount(
            email: "me@outlook.com", host: "outlook.office365.com", port: 993,
            smtpHost: "smtp.office365.com", smtpPort: 587, smtpSecurity: "starttls", authProvider: "microsoft"
        )
        var settings = Settings.default
        settings.savedAccounts = [microsoft]
        let app = AppState(
            persistence: AppStateMemoryPersistence(settings: settings),
            secrets: InMemorySecretStore(),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
        app.upsertSavedAccount(email: "ME@outlook.com", host: "outlook.office365.com", port: 993)
        let kept = app.savedAccounts.first
        XCTAssertEqual(app.savedAccounts.count, 1)
        XCTAssertEqual(kept?.smtpHost, "smtp.office365.com")
        XCTAssertEqual(kept?.smtpSecurity, "starttls")
        XCTAssertEqual(kept?.authProvider, "microsoft")
    }
}
