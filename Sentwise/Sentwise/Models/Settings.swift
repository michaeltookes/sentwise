import Foundation

/// What happens when the user approves a generated draft.
enum SendBehavior: String, CaseIterable, Equatable {
    /// Create a Gmail draft via IMAP `APPEND` (nothing is sent).
    case saveAsDraft
    /// Send the reply immediately over SMTP.
    case autoSend

    /// The safer default: save a draft rather than send automatically.
    static let `default`: SendBehavior = .saveAsDraft
}

/// Non-secret application settings, persisted as JSON.
///
/// `schemaVersion` lets future versions migrate older files, and unknown/missing
/// keys decode to defaults. Secrets are never stored here — the mail app
/// password lives in the Keychain.
struct Settings: Codable, Equatable {

    /// The current settings schema version.
    static let currentSchemaVersion = 17

    /// Schema version that introduced the persisted onboarding completion flag.
    static let onboardingCompletionSchemaVersion = 6

    /// Schema version that introduced persisted IMAP host guidance ownership.
    static let mailHostGuidanceSchemaVersion = 7

    /// Schema version that introduced host ownership before an email is entered.
    static let pendingMailHostGuidanceSchemaVersion = 8

    /// Schema version that introduced the per-provider custom LLM base URL.
    static let llmBaseURLSchemaVersion = 9

    /// Schema version that introduced the auto-send safety-net delay (item 23).
    static let sendDelaySchemaVersion = 10

    /// Schema version that introduced remembered saved accounts (item 48). On
    /// first launch at this version, the existing single account is migrated
    /// into `savedAccounts` and its app password moves from the legacy shared
    /// Keychain slot to a per-account key.
    static let savedAccountsSchemaVersion = 11

    /// Schema version that introduced the sender allow/blocklist rules (item 18).
    /// Purely additive: older files decode the two lists as empty.
    static let senderRulesSchemaVersion = 12

    /// Schema version that introduced the optional transcript watched folder
    /// (item 51). Purely additive: older files decode it as off with no path.
    static let transcriptWatchedFolderSchemaVersion = 13

    /// Schema version that introduced the watched-folder seen-version baseline.
    /// Purely additive: older files decode it as unestablished and seed once.
    static let transcriptWatchedFolderSeenSnapshotsSchemaVersion = 14

    /// Schema version that introduced managed inference (item 56a). On first
    /// launch at this version, an install with no configured BYO provider moves to
    /// the managed provider; a configured BYO user keeps their provider.
    static let managedInferenceSchemaVersion = 15

    /// Schema version that introduced the signature policy + custom text (item
    /// 24). Purely additive: older files decode the policy as `none` (append
    /// nothing) with an empty custom signature, a safe default for existing
    /// installs.
    static let signatureSchemaVersion = 16

    /// Schema version that introduced the verbose diagnostic-logging toggle (item
    /// 36). Purely additive: older files decode it as off (normal logging), the
    /// safe default. The terminal launch migration stamps this version.
    static let verboseDiagnosticLoggingSchemaVersion = 17

    /// The default auto-send undo window, in seconds (item 23). Zero disables it.
    static let defaultSendDelaySeconds = 10

    /// The largest auto-send undo window we persist, in seconds.
    static let maxSendDelaySeconds = 300

    /// Schema version of the persisted file.
    var schemaVersion: Int

    /// How often (in seconds) the inbox is polled while the Mac is awake.
    var pollIntervalSeconds: Int

    /// The connected mailbox email address (non-secret).
    var mailEmail: String

    /// The IMAP host.
    var mailHost: String

    /// Email address the configured host was explicitly or successfully tied to.
    var mailHostGuidanceEmail: String?

    /// Whether the configured host was explicitly entered before an email existed.
    var mailHostGuidancePendingEmail: Bool

    /// The IMAP port.
    var mailPort: Int

    /// Accounts the user has connected and can switch between without re-entering
    /// credentials (item 48). Non-secret connection details only — each account's
    /// app password lives in the Keychain under its own per-account key. The
    /// *active* account is the one whose email matches `mailEmail`.
    var savedAccounts: [SavedMailAccount]

    /// The selected LLM provider (raw value of `LLMProviderKind`). Stored as a
    /// string so an unknown/future provider decodes gracefully to the default.
    var llmProvider: String

    /// The chosen model id, or empty to use the provider's default model.
    var llmModel: String

    /// An optional custom base URL for the selected provider (BYO gateway/proxy).
    /// Empty means the provider's default endpoint. Only honored by providers
    /// whose `supportsCustomBaseURL` is true (the OpenAI-compatible adapter).
    var llmBaseURL: String

    /// The resolved model id that last passed a connection test.
    var llmVerifiedModel: String

    /// The email of the signed-in managed-inference account (item 56a), for the
    /// "Connected as …" display. Non-secret; the device/session tokens live in the
    /// Keychain. Empty when not signed in.
    var managedAccountEmail: String

    /// How a signature is applied to generated drafts (raw value of
    /// `SignaturePolicy`, item 24). Stored as a string so an unknown/future value
    /// decodes gracefully to the default (`none`).
    var signaturePolicy: String

    /// The user's custom signature text, appended to drafts when the policy is
    /// `custom` and the draft doesn't already end with a signature. Only
    /// meaningful for the `custom` policy; empty otherwise.
    var signatureText: String

    /// What approving a draft does (raw value of `SendBehavior`). Stored as a
    /// string so an unknown/future value decodes gracefully to the default.
    var sendBehavior: String

    /// The auto-send safety-net window (item 23), in seconds. After the user
    /// approves an auto-send draft, the app waits this long — showing a Cancel
    /// affordance — before actually sending. Zero disables the window (instant
    /// send). Only meaningful in auto-send mode; save-as-draft is unaffected.
    var sendDelaySeconds: Int

    /// Whether the user has finished (or explicitly dismissed) the first-run
    /// onboarding flow. Old files without this key decode to `false`; an
    /// already-configured install is treated as complete at launch.
    var onboardingCompleted: Bool

    /// Senders the watcher should always draft, bypassing the reply-worthiness
    /// heuristics (item 18). Each entry is a full address or a whole domain.
    var senderAllowlist: [SenderRule]

    /// Senders the watcher should never draft; matches are skipped with a visible
    /// reason (item 18). Each entry is a full address or a whole domain.
    var senderBlocklist: [SenderRule]

    /// Whether verbose diagnostic logging is enabled (item 36). Off by default —
    /// normal logging. When on, the app emits additional `debug`/`info` detail and
    /// the "Report a Problem" bundle includes those lower-level entries so a bug
    /// report is richer. Purely non-secret; never affects what mail content is
    /// logged (that is never logged at any level).
    var verboseDiagnosticLogging: Bool

    /// Whether the transcript watched folder is active (item 51). Off by default.
    var transcriptWatchedFolderEnabled: Bool

    /// The folder watched for new transcript files (e.g. Zoom's local recording
    /// directory). Empty when unset. Only meaningful while the feature is enabled.
    var transcriptWatchedFolderPath: String

    /// Version snapshots the watched-folder source has accepted or explicitly
    /// seeded as pre-existing. `nil` means the baseline has not been established
    /// for the currently configured folder.
    var transcriptWatchedFolderSeenSnapshots: [String: WatchedFolderFileSnapshot]?

    init(
        schemaVersion: Int,
        pollIntervalSeconds: Int,
        mailEmail: String = "",
        mailHost: String = "imap.gmail.com",
        mailHostGuidanceEmail: String? = nil,
        mailHostGuidancePendingEmail: Bool = false,
        mailPort: Int = 993,
        savedAccounts: [SavedMailAccount] = [],
        llmProvider: String = "managed",
        llmModel: String = "",
        llmBaseURL: String = "",
        llmVerifiedModel: String = "",
        managedAccountEmail: String = "",
        signaturePolicy: String = SignaturePolicy.default.rawValue,
        signatureText: String = "",
        sendBehavior: String = SendBehavior.default.rawValue,
        sendDelaySeconds: Int = Settings.defaultSendDelaySeconds,
        onboardingCompleted: Bool = false,
        senderAllowlist: [SenderRule] = [],
        senderBlocklist: [SenderRule] = [],
        verboseDiagnosticLogging: Bool = false,
        transcriptWatchedFolderEnabled: Bool = false,
        transcriptWatchedFolderPath: String = "",
        transcriptWatchedFolderSeenSnapshots: [String: WatchedFolderFileSnapshot]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.pollIntervalSeconds = pollIntervalSeconds
        self.mailEmail = mailEmail
        self.mailHost = mailHost
        self.mailHostGuidanceEmail = mailHostGuidanceEmail
        self.mailHostGuidancePendingEmail = mailHostGuidancePendingEmail
        self.mailPort = mailPort
        self.savedAccounts = savedAccounts
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.llmBaseURL = llmBaseURL
        self.llmVerifiedModel = llmVerifiedModel
        self.managedAccountEmail = managedAccountEmail
        self.signaturePolicy = signaturePolicy
        self.signatureText = signatureText
        self.sendBehavior = sendBehavior
        self.sendDelaySeconds = sendDelaySeconds
        self.onboardingCompleted = onboardingCompleted
        self.senderAllowlist = senderAllowlist
        self.senderBlocklist = senderBlocklist
        self.verboseDiagnosticLogging = verboseDiagnosticLogging
        self.transcriptWatchedFolderEnabled = transcriptWatchedFolderEnabled
        self.transcriptWatchedFolderPath = transcriptWatchedFolderPath
        self.transcriptWatchedFolderSeenSnapshots = transcriptWatchedFolderSeenSnapshots
    }

    /// Default settings for a fresh install.
    static let `default` = Settings(
        schemaVersion: currentSchemaVersion,
        pollIntervalSeconds: 300
    )

    enum CodingKeys: String, CodingKey {
        case schemaVersion, pollIntervalSeconds, mailEmail, mailHost, mailHostGuidanceEmail
        case mailHostGuidancePendingEmail, mailPort, savedAccounts
        case llmProvider, llmModel, llmBaseURL, llmVerifiedModel, managedAccountEmail
        case signaturePolicy, signatureText
        case sendBehavior, sendDelaySeconds, onboardingCompleted
        case senderAllowlist, senderBlocklist, verboseDiagnosticLogging
        case transcriptWatchedFolderEnabled, transcriptWatchedFolderPath, transcriptWatchedFolderSeenSnapshots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Settings.currentSchemaVersion
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 300
        mailEmail = try container.decodeIfPresent(String.self, forKey: .mailEmail) ?? ""
        mailHost = try container.decodeIfPresent(String.self, forKey: .mailHost) ?? "imap.gmail.com"
        mailHostGuidanceEmail = try container.decodeIfPresent(String.self, forKey: .mailHostGuidanceEmail)
        mailHostGuidancePendingEmail =
            try container.decodeIfPresent(Bool.self, forKey: .mailHostGuidancePendingEmail) ?? false
        mailPort = try container.decodeIfPresent(Int.self, forKey: .mailPort) ?? 993
        savedAccounts = try container.decodeIfPresent([SavedMailAccount].self, forKey: .savedAccounts) ?? []
        llmProvider = try container.decodeIfPresent(String.self, forKey: .llmProvider) ?? "anthropic"
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel) ?? ""
        llmBaseURL = try container.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? ""
        llmVerifiedModel = try container.decodeIfPresent(String.self, forKey: .llmVerifiedModel) ?? ""
        managedAccountEmail = try container.decodeIfPresent(String.self, forKey: .managedAccountEmail) ?? ""
        signaturePolicy =
            try container.decodeIfPresent(String.self, forKey: .signaturePolicy) ?? SignaturePolicy.default.rawValue
        signatureText = try container.decodeIfPresent(String.self, forKey: .signatureText) ?? ""
        sendBehavior = try container.decodeIfPresent(String.self, forKey: .sendBehavior) ?? SendBehavior.default.rawValue
        sendDelaySeconds =
            try container.decodeIfPresent(Int.self, forKey: .sendDelaySeconds) ?? Settings.defaultSendDelaySeconds
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        senderAllowlist = try container.decodeIfPresent([SenderRule].self, forKey: .senderAllowlist) ?? []
        senderBlocklist = try container.decodeIfPresent([SenderRule].self, forKey: .senderBlocklist) ?? []
        verboseDiagnosticLogging =
            try container.decodeIfPresent(Bool.self, forKey: .verboseDiagnosticLogging) ?? false
        transcriptWatchedFolderEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .transcriptWatchedFolderEnabled) ?? false
        transcriptWatchedFolderPath =
            try container.decodeIfPresent(String.self, forKey: .transcriptWatchedFolderPath) ?? ""
        transcriptWatchedFolderSeenSnapshots =
            try container.decodeIfPresent(
                [String: WatchedFolderFileSnapshot].self,
                forKey: .transcriptWatchedFolderSeenSnapshots
            )
    }

    /// Returns a copy with values clamped to sane ranges.
    func validated() -> Settings {
        var copy = self
        copy.pollIntervalSeconds = min(max(pollIntervalSeconds, 30), 3600)
        copy.mailPort = min(max(mailPort, 1), 65535)
        copy.sendDelaySeconds = min(max(sendDelaySeconds, 0), Settings.maxSendDelaySeconds)
        copy.llmBaseURL = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.signatureText = signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStoredGuidanceHost = !copy.mailHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if copy.mailHost.isEmpty && copy.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.mailHost = "imap.gmail.com"
        }
        if let guidanceEmail = copy.mailHostGuidanceEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !guidanceEmail.isEmpty {
            copy.mailHostGuidanceEmail = guidanceEmail
        } else {
            copy.mailHostGuidanceEmail = nil
        }
        if copy.mailHostGuidancePendingEmail,
           !hasStoredGuidanceHost {
            copy.mailHostGuidancePendingEmail = false
        }
        copy.savedAccounts = Self.normalizedSavedAccounts(savedAccounts)
        copy.senderAllowlist = Self.dedupedRules(senderAllowlist)
        copy.senderBlocklist = Self.dedupedRules(senderBlocklist)
        copy.transcriptWatchedFolderPath = transcriptWatchedFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.transcriptWatchedFolderPath.isEmpty || !copy.transcriptWatchedFolderEnabled {
            copy.transcriptWatchedFolderSeenSnapshots = nil
        }
        return copy
    }

    /// Collapses duplicate rules (by normalized pattern) to a single entry,
    /// keeping the first occurrence's order.
    static func dedupedRules(_ rules: [SenderRule]) -> [SenderRule] {
        var seen = Set<String>()
        return rules.filter { seen.insert($0.pattern).inserted }
    }

    /// Drops entries with no usable email and collapses duplicates (by normalized
    /// email) to a single entry, keeping the first occurrence's details.
    static func normalizedSavedAccounts(_ accounts: [SavedMailAccount]) -> [SavedMailAccount] {
        var seen = Set<String>()
        var result: [SavedMailAccount] = []
        for account in accounts {
            let identity = SavedMailAccount.normalizedEmail(account.email)
            guard !identity.isEmpty, !seen.contains(identity) else { continue }
            seen.insert(identity)
            result.append(account)
        }
        return result
    }
}
