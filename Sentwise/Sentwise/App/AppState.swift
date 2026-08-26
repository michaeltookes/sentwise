import Combine
import SentwiseMail
import os
import SwiftUI

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "AppState")

/// Central application state container and single source of truth for observed app state.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Watch State

    /// High-level state of the inbox watcher.
    enum WatchStatus: Equatable {
        case idle
        case watching
        case paused
    }

    /// Current watcher status. Drives the menu-bar status line.
    @Published var watchStatus: WatchStatus = .idle

    /// Number of drafts awaiting the user's approval.
    @Published var pendingDraftCount: Int = 0

    /// System notification-authorization status (item 78); see
    /// `AppState+NotificationPermission`. Starts `.authorized` (non-nagging).
    @Published var notificationPermission: NotificationPermission = .authorized

    /// Whether an email account is connected.
    @Published var isAccountConnected: Bool = false

    /// Whether a connection attempt is in progress.
    @Published var isConnecting: Bool = false

    /// A user-facing message describing the last connection error, if any.
    @Published var connectionError: String?

    // MARK: - Mail Account Inputs (bound to Settings fields)

    @Published var mailEmail: String
    @Published var mailAppPassword: String
    @Published var mailHost: String
    @Published var mailPort: Int
    var mailHostExplicitlyEditedEmail: String?
    var mailHostExplicitlyEditedBeforeEmail = false

    /// Accounts the user has connected and can switch between without re-entering
    /// credentials (item 48). The active account is the one whose email matches
    /// `mailEmail`; each account's app password lives in its own Keychain item.
    @Published var savedAccounts: [SavedMailAccount] = []

    // MARK: - Recent Messages (preview)

    /// The most recently fetched messages (envelope-level), newest first.
    @Published var recentMessages: [MailMessage] = []

    /// Whether a fetch is in progress.
    @Published var isFetching: Bool = false

    /// A user-facing message describing the last fetch error, if any.
    @Published var fetchError: String?

    /// The readable body of the message the user opened, if any.
    @Published var openedBody: MailBodyPreview?

    /// Whether a body fetch is in progress.
    @Published var isFetchingBody: Bool = false

    /// A user-facing message describing the last body-fetch error, if any.
    @Published var bodyError: String?

    // MARK: - AI Provider (bound to Settings fields)

    /// The selected LLM provider.
    @Published var llmProviderKind: LLMProviderKind
    /// The chosen model id (empty = provider default).
    @Published var llmModel: String
    /// Optional custom base URL (BYO gateway/proxy; used only where the provider's `supportsCustomBaseURL` is true).
    @Published var llmBaseURL: String
    /// The API key input (persisted to Keychain on a successful test).
    @Published var llmAPIKey: String
    /// Whether an LLM provider is connected (a verified key is stored).
    @Published var isLLMConnected: Bool = false
    /// Whether an LLM connection test is in progress.
    @Published var isTestingLLM: Bool = false
    /// Whether OpenRouter provisioning has opened the browser and is waiting for
    /// the callback. Backed by the persisted PKCE verifier so relaunches keep the
    /// button from starting a second flow over the first.
    @Published var isOpenRouterProvisioning: Bool = false
    /// A user-facing message describing the last LLM error, if any.
    @Published var llmError: String?

    /// The resolved model id that last passed a connection test.
    var verifiedLLMModel: String

    // MARK: - Managed inference account (item 56a)

    /// Signed-in managed account email, for "Connected as …".
    @Published var managedAccountEmail: String
    /// Whether a managed account is signed in (device + session tokens stored).
    @Published var isManagedSignedIn: Bool = false
    /// Stage of the email-code sign-in flow.
    @Published var managedSignInStage: ManagedSignInStage = .idle
    /// Whether a managed sign-in / sign-out request is in flight.
    @Published var managedBusyAction: ManagedBusyAction?
    /// Last managed-account error, if any.
    @Published var managedError: String?
    /// Email and OTP code typed into the managed sign-in form.
    @Published var managedEmailInput: String = ""
    @Published var managedCodeInput: String = ""
    /// Email address tied to the current Clerk pending sign-in handle. This is
    /// transient like the handle itself, so it is intentionally not persisted.
    var pendingManagedSignInEmail: String?

    // MARK: - Voice Profile

    /// The learned voice profile, or `nil` if none has been learned yet.
    @Published var voiceProfile: VoiceProfile?
    /// Whether voice learning is in progress.
    @Published var isLearningVoice: Bool = false
    /// A short progress message shown while learning.
    @Published var voiceProgress: String?
    /// A user-facing message describing the last voice-learning error, if any.
    @Published var voiceError: String?

    // MARK: - Draft (preview)

    /// The most recently generated reply draft, if any.
    @Published var generatedDraft: Draft?
    /// Whether a draft is being generated.
    @Published var isGeneratingDraft: Bool = false
    /// A user-facing message describing the last draft error, if any.
    @Published var draftError: String?
    /// Whether the current draft is being saved to the Drafts mailbox.
    @Published var isSavingDraft: Bool = false
    /// A confirmation message shown after a successful save, if any.
    @Published var draftSavedMessage: String?
    /// Whether the current draft is being sent over SMTP.
    @Published var isSendingDraft: Bool = false
    /// A confirmation message shown after a successful send, if any.
    @Published var draftSentMessage: String?

    // MARK: - Preferences

    /// Whether the app launches at login (mirrors `SMAppService` state).
    @Published private(set) var launchAtLogin = LoginItemManager.shared.isEnabled

    /// How often (in seconds) the inbox is polled while the Mac is awake.
    @Published var pollIntervalSeconds: Int

    /// How a signature is applied to generated drafts (item 24). Restored from
    /// persisted settings at launch by `restoreDraftPreferences(from:)`.
    @Published var signaturePolicy: SignaturePolicy = .default

    /// The user's custom signature text, appended to drafts under the `.custom`
    /// policy unless the draft already ends with a signature.
    @Published var signatureText: String = ""

    /// Whether a "Suggest from my Sent mail" signature detection is in flight.
    @Published var isDetectingSignature: Bool = false

    /// User-facing result of the last signature detection (success or failure).
    /// Non-nil after a detection attempt so feedback is never silent (item 24).
    @Published var signatureDetectionMessage: String?

    /// Whether the last detection succeeded, for styling the feedback message.
    /// `nil` when no detection has run.
    @Published var signatureDetectionSucceeded: Bool?

    /// What approving a draft does: save a Gmail draft or send immediately.
    /// Restored from persisted settings at launch by `restoreDraftPreferences`.
    @Published var sendBehavior: SendBehavior = .default

    /// The auto-send safety-net window in seconds (item 23). After approving an
    /// auto-send draft the app waits this long — with a Cancel affordance —
    /// before sending. Zero disables the window (instant send).
    @Published var sendDelaySeconds: Int = Settings.defaultSendDelaySeconds

    /// Whether first-run onboarding has been completed or dismissed.
    @Published var onboardingCompleted: Bool

    /// Senders to always draft, bypassing the reply-worthiness heuristics (item 18).
    @Published var senderAllowlist: [SenderRule]

    /// Senders to never draft; matches are skipped with a visible reason (item 18).
    @Published var senderBlocklist: [SenderRule]

    /// Whether verbose diagnostic logging is enabled (item 36). Off by default.
    /// `setupAutoSave` mirrors it into the global `DiagnosticLog.isVerbose`.
    @Published var verboseDiagnosticLogging: Bool

    /// Whether the loaded settings file predates the onboarding completion flag.
    /// Used only to keep already-configured installs out of first-run setup.
    let loadedSettingsPredateOnboardingCompletion: Bool

    // MARK: - Transcript Watched Folder (item 51)

    /// Whether the transcript watched folder is active. Off by default.
    @Published var transcriptWatchedFolderEnabled: Bool

    /// The folder watched for new transcript files (e.g. Zoom's recording dir).
    @Published var transcriptWatchedFolderPath: String

    /// Persisted accepted/seeded file snapshots for the current watched folder.
    var transcriptWatchedFolderSeenSnapshots: [String: WatchedFolderFileSnapshot]?

    /// The live folder watcher, created when watching starts. `nil` while idle.
    var transcriptFolderSource: WatchedFolderTranscriptSource?

    /// A user-facing message describing the last watched-folder error, if any.
    @Published var transcriptFolderError: String?

    // MARK: - Mailbox Browser (item 40)

    /// Search inputs and results for the mailbox browser window.
    @Published var browser = MailboxBrowserState()

    // MARK: - Bulk Cleanup (item 42)

    /// Chosen bulk action, preview, and run progress.
    @Published var bulk = BulkCleanupState()

    // MARK: - Inbox Watcher

    /// Drafts the watcher has produced and enqueued, awaiting approval (item 8).
    @Published var pendingDrafts: [Draft] = []

    /// Identities of pending drafts currently being approved (send/save in flight).
    @Published var approvingDraftIDs: Set<String> = []
    var pendingDraftUncommittedEditIDs: Set<String> = []
    var pendingDraftUncommittedEditBodies: [String: String] = [:]
    var pendingDraftUncommittedEditRecipients: [String: [MailAddress]] = [:]
    var pendingDraftInvalidRecipientEditIDs: Set<String> = []
    /// A user-facing message describing the last approve/deny error, if any.
    @Published var approvalError: String?

    /// Stale-thread warnings raised at approval time, keyed by draft identity.
    @Published var pendingStaleWarnings: [String: StaleThreadReason] = [:]

    /// Remaining seconds on an in-progress auto-send countdown (item 23), keyed by
    /// draft identity. Presence means that draft is counting down; the review UI
    /// shows "Sending in Ns…" with a Cancel button while an entry exists.
    @Published var pendingSendCountdowns: [String: Int] = [:]

    /// The live per-draft countdown tasks (item 23), keyed by draft identity.
    /// Cancelling one stops its send; the draft remains pending untouched.
    var sendCountdownTasks: [String: Task<Void, Never>] = [:]

    /// Countdown draft identities that originated from notification approval and
    /// need explicit user feedback if the delayed dispatch is blocked.
    var sendCountdownNotificationApprovalIDs: Set<String> = []

    /// One countdown tick, in nanoseconds. Overridable so tests can drive the
    /// window without waiting real seconds (mirrors `bulkSweepPacingNanoseconds`).
    var sendCountdownTickNanoseconds: UInt64 = 1_000_000_000

    /// A user-facing message describing the last inbox-poll error, if any.
    @Published var watchError: String?

    // MARK: - Resilience (item 27)

    /// Whether the network currently appears reachable. Drives the offline-pause
    /// of the poll loop and the "waiting for network" draft state. Starts `true`
    /// so headless/test construction behaves as online until told otherwise.
    @Published var isOnline: Bool = true

    /// Identities of approved drafts deferred because the network was offline at
    /// dispatch time (item 27). They stay in `pendingDrafts` — that reuse *is* the
    /// offline queue — and dispatch on reconnect. Hydrated from each draft's
    /// persisted, still-waiting `offlineQueuedDispatch` intent at launch.
    @Published var draftsWaitingForNetwork: Set<String> = []

    /// The intended dispatch for each offline-queued draft, so reconnect
    /// re-dispatches send-vs-save and force overrides exactly as approved.
    var offlineQueuedDispatch: [String: OfflineQueuedDraftDispatch] = [:]

    /// The shared exponential-backoff driver for resilient operations (send,
    /// save, poll-fetch, watcher draft). Overridable so tests drive backoff
    /// deterministically without real waits (mirrors `sendCountdownTickNanoseconds`).
    var retryRunner = RetryRunner()
    /// Set after the reachability monitor delivers its first concrete path.
    var hasConfirmedReachability = false
    /// Prevents overlapping reconnect drains from racing each other.
    var isResumingQueuedDrafts = false
    /// Records a reconnect callback that arrived while the current queue drain
    /// was already running, so the drain can replay missed queued work once.
    var needsQueuedDraftDrainAfterCurrent = false
    /// Set when a managed-auth failure paused the watcher; cleared on start/stop or after reauth resumes it.
    var resumeWatchingAfterManagedReauth = false

    /// Observes reachability so the app can pause while offline and resume on
    /// reconnect. Injected for deterministic offline→online tests.
    let reachability: NetworkReachabilityMonitoring
    /// Messages the watcher passed over instead of drafting, newest first.
    /// This rolling operational log is in-memory only.
    @Published var skippedMessages: [SkippedMessage] = []

    var skippedMessageIDs: Set<String> = []
    var skippedMessageReasonsByID: [String: ReplyWorthinessReason] = [:]

    /// Maximum number of skip-log entries kept in memory.
    let skippedMessageLogLimit = 100
    /// User-facing activity history (item 21), newest first; see `AppState+Activity`.
    @Published var activityEvents: [ActivityEvent] = []

    /// Messages the watcher has already handled, so none is drafted twice.
    var processedMessages: ProcessedMessages

    /// Reentrancy guard so overlapping polls can't double-process the inbox.
    var isPollingInbox = false

    /// The scheduling half of the watcher; the poll policy is `pollInboxOnce`.
    private(set) var inboxWatcher: InboxWatcher!

    /// How many recent inbox messages each poll inspects before catch-up expansion.
    let watchFetchLimit = 20

    /// Maximum messages to inspect when catch-up pages back to the watcher baseline.
    let watchCatchUpFetchLimit = ProcessedMessages.limit

    // MARK: - Private

    /// Internal (not private) so the `AppState+Voice` extension can reach it.
    let persistence: PersistenceProvider
    /// Internal (not private) so the `AppState+LLM`/`+Voice` extensions can reach it.
    let secrets: SecretStore
    /// Internal (not private) so the `AppState+Voice` extension can reach it.
    let mailProvider: MailProvider
    let llm: LLMProviding
    /// The managed-inference account (item 56a): Clerk sign-in + session-token
    /// minting. Also the `ManagedSessionProviding` behind the production LLM
    /// service, so managed drafting authenticates with the account session.
    let managedAccount: ManagedAccountService
    /// Posts draft-ready notifications and routes their actions back.
    let notifier: DraftNotifying
    /// Set by the menu-bar controller so a notification "open" action (or a
    /// menu click) can surface the review window.
    var openReviewHandler: (() -> Void)?
    /// Set by the menu-bar controller so the app can surface the first-run
    /// onboarding window at launch or from the menu.
    var openOnboardingHandler: (() -> Void)?
    let settingsDebouncer = Debouncer(delay: 0.5)
    /// Internal (not private) so `AppState+SettingsPersistence` can wire the
    /// autosave sinks that observe the published preferences.
    var cancellables = Set<AnyCancellable>()
    var previewGeneration = 0
    var bodyPreviewGeneration = 0
    var draftGeneration = 0
    var browserGeneration = 0
    var bulkGeneration = 0

    /// Pause between bulk-cleanup sweeps so rapid scans do not trip provider rate limits.
    var bulkSweepPacingNanoseconds: UInt64 = 1_200_000_000

    // MARK: - Initialization

    init(
        persistence: PersistenceProvider = PersistenceService.shared,
        secrets: SecretStore = KeychainStore.shared,
        mailProvider: MailProvider = IMAPMailProvider(),
        llm: LLMProviding? = nil,
        managedAccount: ManagedAccountService? = nil,
        notifier: DraftNotifying = NullDraftNotifier(),
        reachability: NetworkReachabilityMonitoring = NetworkReachabilityMonitor()
    ) {
        self.persistence = persistence
        self.secrets = secrets
        self.mailProvider = mailProvider
        // Managed account (item 56a) + wire it as the LLM session provider.
        let managedAccount = managedAccount ?? ManagedAccountService(secrets: secrets)
        self.managedAccount = managedAccount
        self.llm = llm ?? LLMService(managedSessionProvider: managedAccount)
        self.notifier = notifier
        self.reachability = reachability
        self.isOnline = reachability.isOnline
        self.hasConfirmedReachability = reachability.hasCurrentPath

        // Migrate a pre-v11 file to the saved-accounts model before anything reads
        // the mail secret, so the per-account key is populated (item 48). The
        // original (pre-migration) settings drive the schema-version-sensitive
        // guidance/onboarding checks below so those one-shot migrations still fire.
        let loadedSettings = persistence.loadSettings()
        let settings = Self.fullyMigratedSettings(loaded: loadedSettings, secrets: secrets, persistence: persistence)
        self.pollIntervalSeconds = settings.pollIntervalSeconds
        self.onboardingCompleted = settings.onboardingCompleted
        self.senderAllowlist = settings.senderAllowlist
        self.senderBlocklist = settings.senderBlocklist
        self.verboseDiagnosticLogging = settings.verboseDiagnosticLogging
        self.transcriptWatchedFolderEnabled = settings.transcriptWatchedFolderEnabled
        self.transcriptWatchedFolderPath = settings.transcriptWatchedFolderPath
        self.transcriptWatchedFolderSeenSnapshots = settings.transcriptWatchedFolderSeenSnapshots
        self.loadedSettingsPredateOnboardingCompletion =
            loadedSettings.schemaVersion < Settings.onboardingCompletionSchemaVersion
        self.processedMessages = persistence.loadProcessedMessages()
        let pendingState = Self.restoredPendingDraftState(persistence: persistence)
        self.pendingDrafts = pendingState.drafts
        self.pendingDraftCount = pendingState.drafts.count
        self.offlineQueuedDispatch = pendingState.offlineQueuedDispatch
        self.draftsWaitingForNetwork = pendingState.waitingForNetwork
        self.activityEvents = persistence.loadActivityEvents()
        self.mailEmail = settings.mailEmail
        self.mailHost = settings.mailHost
        self.mailPort = settings.mailPort
        self.savedAccounts = settings.savedAccounts
        self.mailHostExplicitlyEditedEmail = settings.mailHostGuidanceEmail
        self.mailHostExplicitlyEditedBeforeEmail = settings.mailHostGuidancePendingEmail
        let activeEmail = settings.mailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let activePassword = Self.storedMailPassword(forEmail: activeEmail, settings: settings, secrets: secrets) ?? ""
        self.mailAppPassword = activePassword

        let managedLaunch = Self.managedLaunchState(settings: settings, secrets: secrets)
        self.llmProviderKind = managedLaunch.provider
        self.llmModel = managedLaunch.llmModel
        self.llmBaseURL = settings.llmBaseURL
        self.verifiedLLMModel = managedLaunch.verifiedLLMModel
        self.llmAPIKey = managedLaunch.apiKey
        self.isOpenRouterProvisioning = secrets.hasValue(for: .openRouterPKCEVerifier)
        self.managedAccountEmail = managedLaunch.hasCredentials ? settings.managedAccountEmail : ""
        self.isManagedSignedIn = managedLaunch.hasCredentials

        self.voiceProfile = persistence.loadVoiceProfile()

        cleanupLegacyOAuthCredentials()
        self.isAccountConnected = !settings.mailEmail.isEmpty && !activePassword.isEmpty
        restoreMailHostGuidanceFromSettings(loadedSettings)
        refreshLLMConnectionStatus()

        // Seed the persisted draft-production preferences before the autosave
        // sinks are wired, so restoring them does not trigger a spurious save.
        restoreDraftPreferences(from: settings)
        setupAutoSave()

        persistRestoredManagedVerificationIfNeeded(managedLaunch, loadedFrom: settings)

        self.inboxWatcher = InboxWatcher(
            interval: { [weak self] in TimeInterval(self?.pollIntervalSeconds ?? 300) },
            onTick: { [weak self] in await self?.pollInboxOnce() }
        )

        installExternalActionHandlers()
    }

    /// Wires the notification-action and reachability-change callbacks. Called
    /// once from `init`; reachability monitoring itself is started later by the
    /// app (not here) so headless/test construction never spins up a real
    /// `NWPathMonitor`.
    private func installExternalActionHandlers() {
        notifier.onAction = { [weak self] action, identity in
            await self?.handleNotificationAction(action, identity: identity)
        }
        reachability.onChange = { [weak self] online in
            self?.handleReachabilityChange(online)
        }
    }

    // MARK: - Launch at Login

    /// Updates the launch-at-login preference via `SMAppService`.
    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItemManager.shared.setEnabled(enabled)
        // Re-read the authoritative status so the UI reflects reality even if
        // the system rejected the change.
        launchAtLogin = LoginItemManager.shared.isEnabled
    }

}
