import SentwiseMail
import SwiftUI

/// The dedicated "Email Account" tab of Settings (item 48). Promotes the cramped
/// inline account controls to their own page and adds saved accounts: the app
/// remembers each connected account so switching between them is a one-tap pick
/// instead of a full re-entry, with each account's app password held in its own
/// Keychain item.
struct EmailAccountSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var openedBody: MailBodyPreview?
    @State private var generatedDraft: Draft?
    @State private var accountPendingRemoval: SavedMailAccount?
    @State private var showDisconnectConfirmation = false
    @State private var newAccountForm = MailAccountFormState()
    @State private var addAccountSession = AddAccountFormSession()
    @FocusState private var isMailEmailFocused: Bool

    private var isAddingAccount: Bool { addAccountSession.isActive }
    /// Whether the credential-entry form is shown: when nothing is connected, or
    /// when the user has explicitly chosen to add another account.
    private var showsConnectForm: Bool {
        !appState.isAccountConnected || isAddingAccount
    }

    var body: some View {
        Form {
            if !appState.savedAccounts.isEmpty {
                savedAccountsSection
            }
            connectionSection
            if appState.isAccountConnected && !isAddingAccount {
                recentMessagesSection
            }
        }
        .formStyle(.grouped)
        .sheet(item: $openedBody, onDismiss: { appState.openedBody = nil }, content: { preview in
            MessageBodyView(preview: preview)
        })
        .sheet(item: $generatedDraft, onDismiss: { appState.generatedDraft = nil }, content: { draft in
            DraftView(draft: draft).environmentObject(appState)
        })
        .alert(
            "Remove account?",
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            ),
            presenting: accountPendingRemoval
        ) { account in
            Button("Remove & Erase Local Data", role: .destructive) {
                appState.removeSavedAccount(account, purgeLocalData: true, messageSurface: .settings)
                accountPendingRemoval = nil
            }
            .accessibilityIdentifier("removeAccountAndErase")
            Button("Remove Only") {
                appState.removeSavedAccount(account, purgeLocalData: false, messageSurface: .settings)
                accountPendingRemoval = nil
            }
            .accessibilityIdentifier("removeAccountOnly")
            Button("Cancel", role: .cancel) { accountPendingRemoval = nil }
        } message: { account in
            Text(EmailAccountSettingsCopy.removeAccountMessage(account.email))
        }
        .confirmationDialog(
            "Disconnect \(appState.mailEmail)?",
            isPresented: $showDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect & Erase Local Data", role: .destructive) {
                appState.disconnectMail(purgeLocalData: true, messageSurface: .settings)
            }
            .accessibilityIdentifier("disconnectAndErase")
            Button("Disconnect Only") {
                appState.disconnectMail(purgeLocalData: false, messageSurface: .settings)
            }
            .accessibilityIdentifier("disconnectOnly")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(EmailAccountSettingsCopy.disconnectMessage)
        }
        .onDisappear {
            abandonAddingAccountIfNeeded()
        }
    }

    // MARK: - Connection / add form
    @ViewBuilder
    private var connectionSection: some View {
        Section(showsConnectForm ? "Add account" : "Email account") {
            if appState.isAccountConnected && !isAddingAccount {
                LabeledContent("Status") {
                    Text("Connected").foregroundStyle(.green)
                }
                LabeledContent("Account") {
                    Text(appState.mailEmail + (appState.activeAccountUsesGoogleSignIn ? " · Signed in with Google" : ""))
                        .foregroundStyle(.secondary)
                }
                if appState.activeAccountUsesGoogleSignIn && appState.isGoogleSignInAvailable {
                    GoogleSignInButtonBlock(
                        auth: appState.googleMailAuth,
                        loginHint: appState.mailEmail,
                        requireHintMatch: true,
                        messageSurface: .settings,
                        shouldApplyResult: { [email = appState.mailEmail, sessionID = addAccountSession.id] _ in
                            self.appState.activeAccountUsesGoogleSignIn && self.appState.mailEmail == email
                                && self.addAccountSession.accepts(sessionID)
                        },
                        onConnected: {}
                    )
                }
                Button("Disconnect", role: .destructive) {
                    showDisconnectConfirmation = true
                }
                .disabled(appState.isConnecting)
                .accessibilityIdentifier("disconnectAccount")
                .accessibilityLabel("Disconnect \(appState.mailEmail)")
                Button {
                    beginAddingAccount()
                } label: {
                    Label("Add another account", systemImage: "plus")
                }
                .accessibilityLabel("Add another account")
            } else {
                connectForm
            }
            if let error = appState.connectionError(for: .settings) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            WorkspaceAuthGuidanceView(messageSurface: .settings, settingsDisplayTab: .account)
        }
    }
    private var connectForm: some View {
        GoogleOrAppPasswordConnect(
            auth: appState.googleMailAuth,
            email: guidanceEmail,
            host: isAddingAccount ? newAccountForm.host : appState.mailHost,
            messageSurface: .settings,
            // Bound to the form session it started in: dropped once the add form is cancelled or reopened.
            shouldApplyResult: { [sessionID = addAccountSession.id] _ in self.addAccountSession.accepts(sessionID) },
            onConnected: { addAccountSession.end(); newAccountForm.resetForNewAccount() },
            appPasswordForm: { appPasswordForm }
        )
    }

    @ViewBuilder
    private var appPasswordForm: some View {
        TextField("Email address", text: mailEmailBinding)
            .textContentType(.username)
            .focused($isMailEmailFocused)
            .onSubmit { commitMailEmailEditFromUser() }
            .onChange(of: isMailEmailFocused) { _, isFocused in
                if !isFocused {
                    commitMailEmailEditFromUser()
                }
            }
            .task(id: guidanceEmail) { await detectGoogleWorkspaceHost(for: guidanceEmail) }
            .accessibilityLabel("Email address")
        SecureField("App password", text: mailAppPasswordBinding)
            .accessibilityLabel("App password")

        HStack {
            Button {
                Task { await connect() }
            } label: {
                if appState.isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Test Connection")
                }
            }
            .disabled(appState.isConnecting)
            .accessibilityLabel("Test connection and save this account")

            if isAddingAccount {
                Button("Cancel") { abandonAddingAccountIfNeeded() }
                    .disabled(appState.isConnecting)
                    .accessibilityLabel("Cancel adding an account")
            }
        }

        AppPasswordGuidanceView(
            email: guidanceEmail,
            explicitHostFallback: guidanceHostFallback
        )

        DisclosureGroup("Advanced (IMAP server)") {
            TextField("IMAP host", text: mailHostBinding)
                .accessibilityLabel("IMAP host")
            TextField("Port", value: mailPortBinding, format: .number)
                .accessibilityLabel("IMAP port")
        }
    }

    // MARK: - Recent messages
    private var recentMessagesSection: some View {
        Section("Recent messages") {
            Button {
                Task { await appState.previewRecentMessages() }
            } label: {
                if appState.isFetching {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Preview inbox")
                }
            }
            .disabled(appState.isFetching)
            .accessibilityLabel("Preview recent inbox messages")

            if let error = appState.fetchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ForEach(appState.recentMessages) { message in
                messageRow(message)
                draftButton(message)
            }

            if appState.isGeneratingDraft {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Drafting a reply…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let error = appState.bodyError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let error = appState.draftError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func messageRow(_ message: MailMessage) -> some View {
        Button {
            Task {
                if let preview = await appState.previewBody(for: message) {
                    openedBody = preview
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MIMEEncodedWord.displaySubject(message.subject))
                        .font(.callout)
                        .lineLimit(1)
                    Text(message.from?.email ?? "unknown sender")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appState.isFetchingBody {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(appState.isFetchingBody)
        .accessibilityLabel("Open message from \(message.from?.email ?? "unknown sender")")
    }

    private func draftButton(_ message: MailMessage) -> some View {
        Button {
            Task {
                if let draft = await appState.generateDraft(for: message) {
                    generatedDraft = draft
                }
            }
        } label: {
            Label("Draft reply", systemImage: "arrowshape.turn.up.left")
                .font(.caption)
        }
        .disabled(appState.isGeneratingDraft || !appState.canGenerateDraft)
        .accessibilityLabel("Draft a reply to this message")
    }

    // MARK: - Actions
    private func connect() async {
        let didConnect: Bool
        if isAddingAccount {
            newAccountForm.commitEmailEditFromUser()
            let credentials = newAccountForm.credentials
            didConnect = await appState.testConnection(with: credentials, messageSurface: .settings) {
                var result = $0; result.discoveredNaming = credentials.discoveredNaming // ignore discovery
                return isAddingAccount && newAccountForm.credentials == result
            }
        } else {
            didConnect = await appState.testConnection(messageSurface: .settings)
        }
        if didConnect && appState.isAccountConnected {
            addAccountSession.end()
            newAccountForm.resetForNewAccount()
        }
    }

    private func switchTo(_ account: SavedMailAccount) async {
        addAccountSession.end()
        newAccountForm.resetForNewAccount()
        await appState.switchToSavedAccount(account, messageSurface: .settings)
    }

    /// Clears only the local add-account form so the connected account remains
    /// active while the user enters and verifies a new one.
    private func beginAddingAccount() {
        newAccountForm.resetForNewAccount()
        appState.setConnectionError(nil, for: .settings)
        appState.clearWorkspaceAuthGuidance(for: .settings)
        addAccountSession.begin()
        isMailEmailFocused = true
    }

    private func abandonAddingAccountIfNeeded() {
        guard isAddingAccount else { return }
        addAccountSession.end()
        // A Google sign-in started from this form is abandoned with it.
        appState.googleMailAuth.cancelSignIn()
        appState.setConnectionError(nil, for: .settings)
        appState.clearWorkspaceAuthGuidance(for: .settings)
        newAccountForm.resetForNewAccount()
    }

    // MARK: - Bindings
    private var guidanceEmail: String {
        isAddingAccount ? newAccountForm.email : appState.mailEmail
    }

    private var guidanceHostFallback: String? {
        isAddingAccount ? newAccountForm.credentialGuidanceHostFallback : appState.credentialGuidanceHostFallback
    }
    private func commitMailEmailEditFromUser() {
        if isAddingAccount {
            newAccountForm.commitEmailEditFromUser()
        } else {
            appState.commitMailEmailEditFromUser()
        }
    }

    private func detectGoogleWorkspaceHost(for email: String) async {
        if isAddingAccount {
            guard let domain = await MailAccountFormState.detectedGoogleWorkspaceDomain(
                for: email, using: appState.googleWorkspaceMXDetector
            ), isAddingAccount else { return }
            newAccountForm.applyGoogleWorkspaceSuggestion(for: domain)
        } else {
            await appState.detectGoogleWorkspaceHost(for: email)
        }
    }

    private var mailHostBinding: Binding<String> {
        Binding(
            get: { isAddingAccount ? newAccountForm.host : appState.mailHost },
            set: {
                if isAddingAccount {
                    let changed = newAccountForm.host != $0
                    newAccountForm.updateHostFromUser($0)
                    if changed {
                    appState.clearWorkspaceAuthGuidance(for: .settings)
                    }
                } else {
                    appState.updateMailHostFromUser($0, messageSurface: .settings)
                }
            }
        )
    }

    private var mailPortBinding: Binding<Int> {
        Binding(
            get: { isAddingAccount ? newAccountForm.port : appState.mailPort },
            set: {
                if isAddingAccount {
                    let changed = newAccountForm.port != $0
                    newAccountForm.port = $0
                    if changed {
                    appState.clearWorkspaceAuthGuidance(for: .settings)
                    }
                } else {
                    appState.updateMailPortFromUser($0, messageSurface: .settings)
                }
            }
        )
    }

    private var mailAppPasswordBinding: Binding<String> {
        Binding(
            get: { isAddingAccount ? newAccountForm.appPassword : appState.mailAppPassword },
            set: {
                if isAddingAccount {
                    let changed = newAccountForm.appPassword != $0
                    newAccountForm.appPassword = $0
                    if changed {
                    appState.clearWorkspaceAuthGuidance(for: .settings)
                    }
                } else {
                    appState.updateMailAppPasswordFromUser($0, messageSurface: .settings)
                }
            }
        )
    }

    private var mailEmailBinding: Binding<String> {
        Binding(
            get: { isAddingAccount ? newAccountForm.email : appState.mailEmail },
            set: {
                if isAddingAccount {
                    let changed = newAccountForm.email != $0
                    newAccountForm.updateEmailFromUser($0)
                    if changed {
                    appState.clearWorkspaceAuthGuidance(for: .settings)
                    }
                } else {
                    appState.updateMailEmailFromUser($0, messageSurface: .settings)
                }
            }
        )
    }
}

// MARK: - Mailboxes list + per-account status (item 99)

extension EmailAccountSettingsView {
    var savedAccountsSection: some View {
        Section("Mailboxes") {
            ForEach(appState.savedAccounts) { account in
                savedAccountRow(account)
            }
            Text(savedAccountsFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func savedAccountRow(_ account: SavedMailAccount) -> some View {
        let isActive = appState.isActiveAccount(account)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    Task { await switchTo(account) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isActive ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email).font(.callout)
                            Text("\(account.host):\(account.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(accountStatusLabel(for: account))
                                .font(.caption2)
                                .foregroundStyle(accountStatusColor(for: account))
                                .lineLimit(1)
                                .accessibilityIdentifier("accountStatus-\(account.id)")
                        }
                        Spacer()
                        if isActive {
                            Text("Active").font(.caption).foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isActive || appState.isConnecting)
                .accessibilityLabel(isActive
                                    ? "\(account.email), active account"
                                    : "Switch to \(account.email)")

                Button(role: .destructive) {
                    accountPendingRemoval = account
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(appState.isConnecting)
                .accessibilityLabel("Remove \(account.email)")
            }
            if appState.savedAccountNeedsGoogleReauth(account) {
                SavedGoogleMailboxReconnect(email: account.email) { [sessionID = addAccountSession.id] _ in
                    self.addAccountSession.accepts(sessionID)
                }
            }
        }
    }

    var savedAccountsFootnote: String {
        if appState.savedAccounts.count > 1 {
            return "Every connected mailbox is watched at the same time, each drafting in "
                + "its own voice. Selecting one makes it the account the connect form edits."
        }
        return "Connect another mailbox below to have Sentwise watch both at once "
            + "(available on Pro and up)."
    }
}
