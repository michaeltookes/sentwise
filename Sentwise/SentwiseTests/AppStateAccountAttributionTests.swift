import SentwiseMail
import XCTest
@testable import Sentwise

/// Account attribution + per-account status surfaced in Review Drafts, Activity,
/// and Settings (item 99).
@MainActor
final class AppStateAccountAttributionTests: XCTestCase {

    private func makeAppState(mailEmail: String, savedAccounts: [SavedMailAccount]) -> AppState {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: mailEmail,
            savedAccounts: savedAccounts
        )
        return AppState(
            persistence: AppStateMemoryPersistence(settings: settings),
            secrets: InMemorySecretStore(seed: [.mailAppPassword(email: mailEmail): "pw"]),
            mailProvider: FakeAppMailProvider(result: .success(())),
            llm: FakeLLMProvider(result: .success(()))
        )
    }

    func testAttributionHiddenForSingleAccount() {
        let app = makeAppState(
            mailEmail: "solo@x.com",
            savedAccounts: [SavedMailAccount(email: "solo@x.com", host: "imap.x.com", port: 993)]
        )
        XCTAssertFalse(app.showsAccountAttribution)
    }

    func testAttributionShownForMultipleAccounts() {
        let app = makeAppState(
            mailEmail: "one@x.com",
            savedAccounts: [
                SavedMailAccount(email: "one@x.com", host: "imap.x.com", port: 993),
                SavedMailAccount(email: "two@y.com", host: "imap.y.com", port: 993)
            ]
        )
        XCTAssertTrue(app.showsAccountAttribution)
        XCTAssertEqual(app.accountAttributionLabel(forEmail: "two@y.com"), "two@y.com")
        XCTAssertNil(app.accountAttributionLabel(forEmail: nil))
        XCTAssertNil(app.accountAttributionLabel(forEmail: "  "))
    }

    func testPerAccountWatchStatusAndHealth() {
        let app = makeAppState(
            mailEmail: "one@x.com",
            savedAccounts: [SavedMailAccount(email: "one@x.com", host: "imap.x.com", port: 993)]
        )
        let background = ConnectedMailAccount(
            email: "two@y.com", host: "imap.y.com", port: 993, appPassword: "pw2"
        )
        background.watchStatus = .paused
        background.watchError = "Authentication failed."
        app.backgroundConnectedAccounts = [background]
        app.watchStatus = .watching

        XCTAssertEqual(app.watchStatus(forAccountEmail: "one@x.com"), .watching)
        XCTAssertEqual(app.watchStatus(forAccountEmail: "two@y.com"), .paused)
        XCTAssertNil(app.watchError(forAccountEmail: "one@x.com"))
        XCTAssertEqual(app.watchError(forAccountEmail: "two@y.com"), "Authentication failed.")
    }
}
