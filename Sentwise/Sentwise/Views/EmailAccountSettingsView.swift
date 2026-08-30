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
    @State private var newAccountForm = MailAccountFormState()
    @State private var isAddingAccount = false
    @FocusState private var isMailEmailFocused: Bool

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
            Button("Remove", role: .destructive) {
                appState.removeSavedAccount(account)
                accountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { accountPendingRemoval = nil }
        } message: { account in
            Text("This forgets \(account.email) and deletes its saved password from your Keychain. "
                 + "Your mail is not affected.")
        }
    }

    // MARK: - Saved accounts

    private var savedAccountsSection: some View {
        Section("Saved accounts") {
            ForEach(appState.savedAccounts) { account in
                savedAccountRow(account)
            }
            Text("Pick an account to switch to it. Switching keeps every account's saved password, "
                 + "so you never have to re-enter it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func savedAccountRow(_ account: SavedMailAccount) -> some View {
        let isActive = appState.isActiveAccount(account)
        return HStack(spacing: 8) {
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
                    Text(appState.mailEmail).foregroundStyle(.secondary)
                }
                Button("Disconnect", role: .destructive) {
                    appState.disconnectMail()
                }
                .disabled(appState.isConnecting)
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

            if let error = appState.connectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            WorkspaceAuthGuidanceView()
        }
    }

    @ViewBuilder
    private var connectForm: some View {
        TextField("Email address", text: mailEmailBinding)
            .textContentType(.username)
            .focused($isMailEmailFocused)
            .onSubmit { commitMailEmailEditFromUser() }
            .onChange(of: isMailEmailFocused) { _, isFocused in
                if !isFocused {
                    commitMailEmailEditFromUser()
                }
            }
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
                Button("Cancel") { cancelAddingAccount() }
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
        if isAddingAccount {
            newAccountForm.commitEmailEditFromUser()
            await appState.testConnection(with: newAccountForm.credentials)
        } else {
            await appState.testConnection()
        }
        if appState.connectionError == nil && appState.isAccountConnected {
            isAddingAccount = false
            newAccountForm.resetForNewAccount()
        }
    }

    private func switchTo(_ account: SavedMailAccount) async {
        isAddingAccount = false
        newAccountForm.resetForNewAccount()
        await appState.switchToSavedAccount(account)
    }

    /// Clears only the local add-account form so the connected account remains
    /// active while the user enters and verifies a new one.
    private func beginAddingAccount() {
        newAccountForm.resetForNewAccount()
        appState.connectionError = nil
        appState.clearWorkspaceAuthGuidance()
        isAddingAccount = true
        isMailEmailFocused = true
    }

    private func cancelAddingAccount() {
        isAddingAccount = false
        appState.connectionError = nil
        appState.clearWorkspaceAuthGuidance()
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

    private var mailHostBinding: Binding<String> {
        Binding(
            get: { isAddingAccount ? newAccountForm.host : appState.mailHost },
            set: {
                if isAddingAccount {
                    newAccountForm.updateHostFromUser($0)
                } else {
                    appState.updateMailHostFromUser($0)
                }
            }
        )
    }

    private var mailPortBinding: Binding<Int> {
        Binding(
            get: { isAddingAccount ? newAccountForm.port : appState.mailPort },
            set: {
                if isAddingAccount {
                    newAccountForm.port = $0
                } else {
                    appState.mailPort = $0
                }
            }
        )
    }

    private var mailAppPasswordBinding: Binding<String> {
        Binding(
            get: { isAddingAccount ? newAccountForm.appPassword : appState.mailAppPassword },
            set: {
                if isAddingAccount {
                    newAccountForm.appPassword = $0
                } else {
                    appState.mailAppPassword = $0
                }
            }
        )
    }

    private var mailEmailBinding: Binding<String> {
        Binding(
            get: { isAddingAccount ? newAccountForm.email : appState.mailEmail },
            set: {
                if isAddingAccount {
                    newAccountForm.updateEmailFromUser($0)
                } else {
                    appState.updateMailEmailFromUser($0)
                }
            }
        )
    }
}
