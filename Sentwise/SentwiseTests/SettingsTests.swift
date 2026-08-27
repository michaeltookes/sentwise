import SwiftUI
import XCTest
@testable import Sentwise

/// Unit tests for the `Settings` model and settings-window support code.
///
/// These are intentionally small — they exist so the CI pipeline has a real
/// test target to run and a place for future logic tests (voice profile,
/// stale-thread detection, provider selection, etc.) to live.
final class SettingsTests: XCTestCase {

    @MainActor
    func testSettingsPaneControllerCacheReusesPaneControllerForTab() {
        let cache = SettingsPaneControllerCache { tab in
            AnyView(Text(tab.rawValue))
        }

        let accountController = cache.controller(for: .account)
        let generalController = cache.controller(for: .general)

        XCTAssertTrue(accountController === cache.controller(for: .account))
        XCTAssertFalse(accountController === generalController)
        XCTAssertEqual(cache.cachedTabCount, 2)
    }

    @MainActor
    func testSettingsPaneControllerCacheClearsControllers() {
        let cache = SettingsPaneControllerCache { tab in
            AnyView(Text(tab.rawValue))
        }

        let firstAccountController = cache.controller(for: .account)
        cache.removeAll()

        XCTAssertFalse(firstAccountController === cache.controller(for: .account))
        XCTAssertEqual(cache.cachedTabCount, 1)
    }

    func testDefaultUsesCurrentSchemaVersion() {
        XCTAssertEqual(Settings.default.schemaVersion, Settings.currentSchemaVersion)
    }

    func testDefaultPollIntervalIsFiveMinutes() {
        XCTAssertEqual(Settings.default.pollIntervalSeconds, 300)
    }

    func testValidatedClampsPollIntervalBelowMinimum() {
        let settings = Settings(schemaVersion: 1, pollIntervalSeconds: 5).validated()
        XCTAssertEqual(settings.pollIntervalSeconds, 30)
    }

    func testValidatedClampsPollIntervalAboveMaximum() {
        let settings = Settings(schemaVersion: 1, pollIntervalSeconds: 100_000).validated()
        XCTAssertEqual(settings.pollIntervalSeconds, 3600)
    }

    func testValidatedKeepsInRangeValueUnchanged() {
        let settings = Settings(schemaVersion: 1, pollIntervalSeconds: 120).validated()
        XCTAssertEqual(settings.pollIntervalSeconds, 120)
    }

    func testValidatedPreservesEmptyHostWhenEmailIsEntered() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@company.example",
            mailHost: ""
        ).validated()
        XCTAssertEqual(settings.mailHost, "")
    }

    func testValidatedRestoresDefaultHostWhenNoEmailIsEntered() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailHost: ""
        ).validated()
        XCTAssertEqual(settings.mailHost, "imap.gmail.com")
    }

    func testValidatedNormalizesHostGuidanceEmail() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailHostGuidanceEmail: " Me@Company.Example "
        ).validated()
        XCTAssertEqual(settings.mailHostGuidanceEmail, "me@company.example")
    }

    func testHostGuidanceEmailRoundTripsThroughCodable() throws {
        let original = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@company.example",
            mailHost: "imap.gmail.com",
            mailHostGuidanceEmail: "me@company.example"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.mailHostGuidanceEmail, "me@company.example")
    }

    func testPendingHostGuidanceRoundTripsThroughCodable() throws {
        let original = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailHost: "imap.gmail.com",
            mailHostGuidancePendingEmail: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(decoded.mailHostGuidancePendingEmail)
    }

    func testValidatedClearsPendingHostGuidanceWithoutHost() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailHost: "",
            mailHostGuidancePendingEmail: true
        ).validated()
        XCTAssertFalse(settings.mailHostGuidancePendingEmail)
    }

    func testValidatedKeepsPendingHostGuidanceWithGuidanceEmail() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailHost: "imap.gmail.com",
            mailHostGuidanceEmail: "me@company.example",
            mailHostGuidancePendingEmail: true
        ).validated()
        XCTAssertEqual(settings.mailHostGuidanceEmail, "me@company.example")
        XCTAssertTrue(settings.mailHostGuidancePendingEmail)
    }

    func testSettingsRoundTripsThroughCodable() throws {
        let original = Settings(
            schemaVersion: 1,
            pollIntervalSeconds: 240,
            llmProvider: "anthropic",
            llmModel: "claude-sonnet-4-6",
            llmVerifiedModel: "claude-sonnet-4-6"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testLegacyFileWithoutLLMKeysDecodesToDefaults() throws {
        // A pre-v3 settings file has no llm keys; they must decode to defaults.
        let legacy = #"{"schemaVersion":2,"pollIntervalSeconds":300,"mailEmail":"me@x.com"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.llmProvider, "anthropic")
        XCTAssertEqual(decoded.llmModel, "")
        XCTAssertEqual(decoded.llmVerifiedModel, "")
    }

    func testCurrentSchemaVersionIsEighteen() {
        XCTAssertEqual(Settings.currentSchemaVersion, 18)
    }

    func testPreGateDraftSweepSchemaVersionIsEighteen() {
        XCTAssertEqual(Settings.preGateDraftSweepSchemaVersion, 18)
    }

    func testSignatureSchemaVersionIsSixteen() {
        XCTAssertEqual(Settings.signatureSchemaVersion, 16)
    }

    func testVerboseDiagnosticLoggingSchemaVersionIsSeventeen() {
        XCTAssertEqual(Settings.verboseDiagnosticLoggingSchemaVersion, 17)
    }

    func testLegacyFileWithoutVerboseLoggingDecodesToOff() throws {
        // A pre-v17 file has no verbose-logging key; it must decode to off (normal
        // logging) — the safe, non-chatty default for existing installs.
        let legacy = #"{"schemaVersion":16,"pollIntervalSeconds":300,"mailEmail":"me@x.com"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.verboseDiagnosticLogging)
    }

    func testVerboseDiagnosticLoggingRoundTripsThroughCodable() throws {
        let original = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            verboseDiagnosticLogging: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(decoded.verboseDiagnosticLogging)
    }

    func testLegacyFileWithoutPreGateSweepFlagDecodesToNotYetRun() throws {
        // A pre-v18 file has no sweep flag; it must decode to `false` so every
        // install that predates the reply-worthiness gate runs the sweep once.
        let legacy = #"{"schemaVersion":17,"pollIntervalSeconds":300,"mailEmail":"me@x.com"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.hasRunPreGateDraftSweep)
    }

    func testPreGateDraftSweepFlagRoundTripsThroughCodable() throws {
        let original = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            hasRunPreGateDraftSweep: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(decoded.hasRunPreGateDraftSweep)
    }

    func testLegacyFileWithoutSignatureKeysDecodesToDefaults() throws {
        // A pre-v16 file has no signature keys; the policy must decode to none
        // (append nothing) with an empty custom signature — the safe default.
        let legacy = #"{"schemaVersion":15,"pollIntervalSeconds":300,"mailEmail":"me@x.com"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.signaturePolicy, SignaturePolicy.none.rawValue)
        XCTAssertEqual(decoded.signatureText, "")
    }

    func testSignatureSettingsRoundTripThroughCodable() throws {
        let original = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            signaturePolicy: SignaturePolicy.custom.rawValue,
            signatureText: "Best,\nJane Doe"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.signaturePolicy, SignaturePolicy.custom.rawValue)
        XCTAssertEqual(decoded.signatureText, "Best,\nJane Doe")
    }

    func testValidatedTrimsSignatureText() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            signatureText: "\n\n  Best,\nJane Doe  \n\n"
        ).validated()
        XCTAssertEqual(settings.signatureText, "Best,\nJane Doe")
    }

    func testUnknownSignaturePolicyResolvesToDefault() {
        // An unknown/future raw value must resolve to the default policy.
        XCTAssertNil(SignaturePolicy(rawValue: "future-policy"))
        XCTAssertEqual(SignaturePolicy.default, .none)
    }

    func testTranscriptWatchedFolderSchemaVersionIsThirteen() {
        XCTAssertEqual(Settings.transcriptWatchedFolderSchemaVersion, 13)
    }

    func testTranscriptWatchedFolderSeenSnapshotsSchemaVersionIsFourteen() {
        XCTAssertEqual(Settings.transcriptWatchedFolderSeenSnapshotsSchemaVersion, 14)
    }

    func testWatchedFolderSettingsRoundTripThroughCodable() throws {
        let snapshot = WatchedFolderFileSnapshot(
            fileSize: 42,
            modificationDate: Date(timeIntervalSince1970: 100),
            creationDate: Date(timeIntervalSince1970: 50),
            fileIdentity: "file-id"
        )
        let original = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            transcriptWatchedFolderEnabled: true,
            transcriptWatchedFolderPath: "/Users/me/Zoom",
            transcriptWatchedFolderSeenSnapshots: ["/Users/me/Zoom/call.txt": snapshot]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        XCTAssertTrue(decoded.transcriptWatchedFolderEnabled)
        XCTAssertEqual(decoded.transcriptWatchedFolderPath, "/Users/me/Zoom")
        XCTAssertEqual(decoded.transcriptWatchedFolderSeenSnapshots, ["/Users/me/Zoom/call.txt": snapshot])
    }

    func testLegacyFileWithoutWatchedFolderSettingsDecodesToDefaults() throws {
        let legacy = #"{"schemaVersion":12,"pollIntervalSeconds":300}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.transcriptWatchedFolderEnabled)
        XCTAssertEqual(decoded.transcriptWatchedFolderPath, "")
        XCTAssertNil(decoded.transcriptWatchedFolderSeenSnapshots)
    }

    func testSavedAccountsSchemaVersionIsEleven() {
        XCTAssertEqual(Settings.savedAccountsSchemaVersion, 11)
    }

    func testSenderRulesSchemaVersionIsTwelve() {
        XCTAssertEqual(Settings.senderRulesSchemaVersion, 12)
    }

    func testLegacyFileWithoutSenderRulesDecodesToEmpty() throws {
        // A pre-v12 file has no sender-rule keys; both lists must decode to empty.
        let legacy = #"{"schemaVersion":11,"pollIntervalSeconds":300,"mailEmail":"me@x.com"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.senderAllowlist.isEmpty)
        XCTAssertTrue(decoded.senderBlocklist.isEmpty)
    }

    func testSenderRulesRoundTripThroughCodable() throws {
        let original = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            senderAllowlist: [SenderRule(normalized: "vip@example.com")],
            senderBlocklist: [SenderRule(normalized: "spam.net")]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.senderAllowlist, original.senderAllowlist)
        XCTAssertEqual(decoded.senderBlocklist, original.senderBlocklist)
    }

    func testLegacyFileWithoutSavedAccountsDecodesToEmpty() throws {
        // A pre-v11 file has no savedAccounts key; it must decode to an empty list.
        let legacy = #"{"schemaVersion":10,"pollIntervalSeconds":300,"mailEmail":"me@x.com"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.savedAccounts.isEmpty)
    }

    func testSavedAccountsRoundTripThroughCodable() throws {
        let original = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: "me@gmail.com",
            savedAccounts: [
                SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993),
                SavedMailAccount(email: "me@att.net", host: "imap.mail.att.net", port: 993)
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.savedAccounts, original.savedAccounts)
    }

    func testValidatedDedupesSavedAccountsByNormalizedEmail() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            savedAccounts: [
                SavedMailAccount(email: "Me@Gmail.com", host: "imap.gmail.com", port: 993),
                SavedMailAccount(email: "me@gmail.com", host: "imap.gmail.com", port: 993),
                SavedMailAccount(email: "  ", host: "imap.gmail.com", port: 993)
            ]
        ).validated()
        XCTAssertEqual(settings.savedAccounts.map(\.email), ["Me@Gmail.com"])
    }

    func testLLMBaseURLSchemaVersionIsNine() {
        XCTAssertEqual(Settings.llmBaseURLSchemaVersion, 9)
    }

    func testSendDelaySchemaVersionIsTen() {
        XCTAssertEqual(Settings.sendDelaySchemaVersion, 10)
    }

    func testDefaultSendDelayIsTenSeconds() {
        XCTAssertEqual(Settings.default.sendDelaySeconds, 10)
        XCTAssertEqual(Settings.defaultSendDelaySeconds, 10)
    }

    func testLegacyFileWithoutSendDelayDecodesToDefault() throws {
        // A pre-v10 settings file has no sendDelaySeconds key; it must decode to
        // the default undo window rather than 0 (instant) so upgrading users get
        // the safety net.
        let legacy = #"{"schemaVersion":9,"pollIntervalSeconds":300,"sendBehavior":"autoSend"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.sendDelaySeconds, Settings.defaultSendDelaySeconds)
    }

    func testSendDelayRoundTripsThroughCodable() throws {
        let original = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            sendBehavior: SendBehavior.autoSend.rawValue,
            sendDelaySeconds: 30
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.sendDelaySeconds, 30)
    }

    func testValidatedClampsNegativeSendDelayToZero() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            sendDelaySeconds: -5
        ).validated()
        XCTAssertEqual(settings.sendDelaySeconds, 0)
    }

    func testValidatedClampsExcessiveSendDelayToMaximum() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            sendDelaySeconds: 100_000
        ).validated()
        XCTAssertEqual(settings.sendDelaySeconds, Settings.maxSendDelaySeconds)
    }

    func testLegacyFileWithoutLLMBaseURLDecodesToEmpty() throws {
        // A pre-v9 settings file has no llmBaseURL key; it must decode to empty.
        let legacy = #"{"schemaVersion":8,"pollIntervalSeconds":300,"llmProvider":"openAICompatible"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.llmBaseURL, "")
    }

    func testLLMBaseURLRoundTripsThroughCodable() throws {
        let original = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmProvider: "openAICompatible",
            llmModel: "gpt-4o-mini",
            llmBaseURL: "https://openrouter.ai/api/v1"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.llmBaseURL, "https://openrouter.ai/api/v1")
    }

    func testValidatedTrimsLLMBaseURL() {
        let settings = Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            llmBaseURL: "  https://openrouter.ai/api/v1  "
        ).validated()
        XCTAssertEqual(settings.llmBaseURL, "https://openrouter.ai/api/v1")
    }

    func testOnboardingCompletionSchemaVersionIsSix() {
        XCTAssertEqual(Settings.onboardingCompletionSchemaVersion, 6)
    }

    func testMailHostGuidanceSchemaVersionIsSeven() {
        XCTAssertEqual(Settings.mailHostGuidanceSchemaVersion, 7)
    }

    func testPendingMailHostGuidanceSchemaVersionIsEight() {
        XCTAssertEqual(Settings.pendingMailHostGuidanceSchemaVersion, 8)
    }

    func testLegacyFileWithoutOnboardingFlagDecodesToNotCompleted() throws {
        // A pre-v6 settings file has no onboarding key; it must decode to false
        // so the flow can run (and be reconciled for already-configured users).
        let legacy = #"{"schemaVersion":5,"pollIntervalSeconds":300,"mailEmail":"me@x.com"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.onboardingCompleted)
    }

    func testOnboardingFlagRoundTripsThroughCodable() throws {
        let original = Settings(schemaVersion: 6, pollIntervalSeconds: 300, onboardingCompleted: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(decoded.onboardingCompleted)
    }
}
