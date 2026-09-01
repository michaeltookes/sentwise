import Foundation
import SentwiseMail

/// Runtime switches for local Prowl accessibility hunts. The documented Prowl
/// app bundle lives under `.prowl/DerivedData`, which enables an isolated mode
/// before startup automation can touch the user's live account.
struct ProwlHuntRuntime {
    static let environmentKey = "SENTWISE_PROWL_HUNT_MODE"
    static let launchArgument = "--sentwise-prowl-hunt-mode"
    static let xctestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

    let isEnabled: Bool

    static var current: ProwlHuntRuntime {
        ProwlHuntRuntime(
            isEnabled: isEnabled(
                environment: ProcessInfo.processInfo.environment,
                arguments: ProcessInfo.processInfo.arguments,
                bundlePath: Bundle.main.bundlePath
            )
        )
    }

    var allowsStartupSideEffects: Bool {
        !isEnabled
    }

    var shouldOpenOnboardingAtLaunch: Bool {
        !isEnabled
    }

    func makePersistenceProvider() -> PersistenceProvider {
        isEnabled
            ? MemoryPersistenceProvider(
                settings: Self.fixtureSettings,
                pendingDrafts: [Self.fixturePendingDraft],
                draftFeedback: Self.fixtureDraftFeedback()
            )
            : PersistenceService.shared
    }

    func makeSecretStore() -> SecretStore {
        isEnabled
            ? InMemorySecretStore(seed: [
                .mailAppPassword(email: Self.fixtureAccountEmail): Self.fixtureAppPassword
            ])
            : KeychainStore.shared
    }

    // MARK: - Seeded fixture (hunt mode only)

    /// Hunt mode seeds a fake connected account so the account-gated menu
    /// surfaces (follow-up composer, review window, mailbox browser) exist and
    /// hunts can open them. The `.invalid` TLD is reserved by RFC 2606 and never
    /// resolves, so nothing in the fixture can reach a real mail server, and no
    /// LLM key is seeded so watching stays unavailable.
    static let fixtureAccountEmail = "hunt.fixture@sentwise.invalid"
    static let fixtureAppPassword = "prowl-hunt-fixture-password"
    static let fixtureMailHost = "imap.sentwise.invalid"

    static var fixtureSettings: Settings {
        Settings(
            schemaVersion: Settings.currentSchemaVersion,
            pollIntervalSeconds: 300,
            mailEmail: fixtureAccountEmail,
            mailHost: fixtureMailHost,
            mailPort: 993,
            savedAccounts: [
                SavedMailAccount(email: fixtureAccountEmail, host: fixtureMailHost, port: 993)
            ],
            onboardingCompleted: true
        )
    }

    /// One pending draft so `hasReviewWindowContent` is true and the Review
    /// Drafts menu item (and window) are reachable. Guardrails forbid approving
    /// or sending it; dispatch would fail against the `.invalid` host anyway.
    static var fixturePendingDraft: Draft {
        Draft(
            id: 1,
            sourceUIDValidity: 1,
            sourceAccountEmail: fixtureAccountEmail,
            sourceMailHost: fixtureMailHost,
            sourceMailPort: 993,
            sourceMailbox: "INBOX",
            sourceSubject: "Prowl hunt fixture",
            sourceFrom: MailAddress(name: "Hunt Fixture", email: "counterpart@sentwise.invalid"),
            sourceReplyTo: nil,
            sourceMessageID: "<prowl-hunt-fixture@sentwise.invalid>",
            incomingBody: "Seeded incoming message so the review window has content during hunts.",
            replySubject: "Re: Prowl hunt fixture",
            body: "Seeded reply draft. Hunts open this window read-only and never approve or send.",
            model: "prowl-hunt-fixture",
            generatedAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    /// A small, fixed set of approval-signal records so the Analytics tab (item 84)
    /// renders deterministic drafting-quality insights during hunts, with zero disk
    /// side effects (the store is the in-memory provider). Records hold codes,
    /// numbers, and hashes only — no message content, matching the item-83 store.
    ///
    /// Timestamps are seeded a few hours apart within the last day, so all three
    /// windows (7-day / 30-day / all-time) contain the same records and the
    /// insights are identical regardless of the selected window. The mix yields
    /// clean, assertable stats: 8 decided drafts (4 as-is, 2 edited, 2 denied) →
    /// one-shot 50%, edited 25%, denied 25%; average edit magnitude 0.30; two
    /// answered-then-approved; deny reasons wrong_tone ×1 and not_worth_replying
    /// ×1; plus 1 abandoned preview (kept out of the rate denominators).
    static func fixtureDraftFeedback(now: Date = Date()) -> [DraftFeedbackRecord] {
        func at(_ hoursAgo: Int) -> Date { now.addingTimeInterval(-Double(hoursAgo) * 3600) }
        func hash(_ seed: Int) -> String {
            DraftFeedbackRecord.hashedIdentity("hunt-fixture-\(seed)@sentwise.invalid")
        }
        return [
            DraftFeedbackRecord(timestamp: at(1), outcome: .approvedAsIs, dispatch: .sent,
                                provenance: .watcher, answeredNeedsInfo: false, draftIdentityHash: hash(1)),
            DraftFeedbackRecord(timestamp: at(2), outcome: .approvedAsIs, dispatch: .saved,
                                provenance: .watcher, answeredNeedsInfo: false, draftIdentityHash: hash(2)),
            DraftFeedbackRecord(timestamp: at(3), outcome: .approvedAsIs, dispatch: .sent,
                                provenance: .manualPreview, answeredNeedsInfo: false, draftIdentityHash: hash(3)),
            DraftFeedbackRecord(timestamp: at(4), outcome: .approvedAsIs, dispatch: .sent,
                                provenance: .authored, answeredNeedsInfo: true, draftIdentityHash: hash(4)),
            DraftFeedbackRecord(timestamp: at(5), outcome: .approvedAfterEdit, dispatch: .sent,
                                editMagnitude: 0.2, provenance: .watcher, answeredNeedsInfo: false,
                                draftIdentityHash: hash(5)),
            DraftFeedbackRecord(timestamp: at(6), outcome: .approvedAfterEdit, dispatch: .saved,
                                editMagnitude: 0.4, provenance: .watcher, answeredNeedsInfo: true,
                                draftIdentityHash: hash(6)),
            DraftFeedbackRecord(timestamp: at(7), outcome: .denied,
                                denyReason: DenyReason(code: .wrongTone), provenance: .watcher,
                                answeredNeedsInfo: false, draftIdentityHash: hash(7)),
            DraftFeedbackRecord(timestamp: at(8), outcome: .denied,
                                denyReason: DenyReason(code: .notWorthReplying), provenance: .watcher,
                                answeredNeedsInfo: false, draftIdentityHash: hash(8)),
            DraftFeedbackRecord(timestamp: at(9), outcome: .abandoned, provenance: .manualPreview,
                                answeredNeedsInfo: false, draftIdentityHash: hash(9)),
        ]
    }

    static func isEnabled(
        environment: [String: String],
        arguments: [String],
        bundlePath: String
    ) -> Bool {
        if isTruthy(environment[environmentKey]) {
            return true
        }
        if arguments.contains(launchArgument) {
            return true
        }
        if environment[xctestConfigurationEnvironmentKey]?.isEmpty == false {
            return true
        }
        return isProwlDerivedDataBundlePath(bundlePath)
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func isProwlDerivedDataBundlePath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard components.count >= 2 else { return false }
        for index in components.indices.dropLast() {
            let next = components.index(after: index)
            if components[index] == ".prowl", components[next] == "DerivedData" {
                return true
            }
        }
        return false
    }
}
