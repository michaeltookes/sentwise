import SentwiseMail
import SwiftUI

/// A resizable window to search, filter, and browse a mailbox for a message to
/// view or reply to (item 40). Powered by `AppState`'s server-side search, so it
/// stays responsive on large, poorly-organized mailboxes.
struct MailboxBrowserView: View {
    @EnvironmentObject var appState: AppState
    @State private var openedBody: MailBodyPreview?
    @State private var generatedDraft: Draft?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            bulkCleanup
            Divider()
            results
        }
        .frame(minWidth: 600, minHeight: 520)
        .task {
            // Default to a recent-messages view (empty search = all, newest
            // first) the first time the window opens.
            if !appState.browser.hasSearched {
                await appState.runMailboxSearch()
            }
        }
        .sheet(item: $openedBody, onDismiss: { appState.openedBody = nil }, content: { preview in
            MessageBodyView(preview: preview)
        })
        .sheet(item: $generatedDraft, onDismiss: { appState.generatedDraft = nil }, content: { draft in
            DraftView(draft: draft).environmentObject(appState)
        })
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            searchRow
            filterRow
        }
        .padding()
    }

    /// Bulk cleanup acts on the current filter, so it sits directly under the
    /// filter controls that define what it would touch (item 42).
    private var bulkCleanup: some View {
        BulkCleanupPanel().environmentObject(appState)
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search mail", text: $appState.browser.keyword)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch() }
                .accessibilityLabel("Search keyword")
            Picker("Folder", selection: mailboxSelection) {
                Text("Inbox").tag(Mailbox.inbox)
                Text("Sent").tag(Mailbox.sent)
                Text("Drafts").tag(Mailbox.drafts)
                if appState.supportsAllMailFolder {
                    Text("All Mail").tag(Mailbox.allMail)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Button("Search") { runSearch() }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.browser.isSearching)
        }
    }

    private var mailboxSelection: Binding<Mailbox> {
        Binding(
            get: { appState.browser.mailbox },
            set: { mailbox in
                guard appState.browser.mailbox != mailbox else { return }
                appState.browser.mailbox = mailbox
                // User-selected folders reload immediately, like any mail client;
                // programmatic account resets only update the model.
                runSearch()
            }
        )
    }

    private var filterRow: some View {
        HStack(spacing: 12) {
            TextField("From", text: $appState.browser.sender)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 190)
                .onSubmit { runSearch() }
                .accessibilityLabel("Filter by sender")
            Picker("Show", selection: $appState.browser.readState) {
                Text("All").tag(MailReadState.any)
                Text("Unread").tag(MailReadState.unreadOnly)
                Text("Read").tag(MailReadState.readOnly)
            }
            .frame(width: 170)
            dateFilter("Since", isOn: $appState.browser.useSinceFilter, date: $appState.browser.since)
            dateFilter("Before", isOn: $appState.browser.useBeforeFilter, date: $appState.browser.before)
            Spacer()
        }
        .font(.callout)
    }

    private func dateFilter(_ label: String, isOn: Binding<Bool>, date: Binding<Date>) -> some View {
        HStack(spacing: 4) {
            Toggle(label, isOn: isOn)
            if isOn.wrappedValue {
                DatePicker("", selection: date, displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel("\(label) date")
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if !appState.browser.results.isEmpty {
            // Keep results visible even if a later "load more" failed — the
            // pagination error surfaces inline in the footer instead.
            resultsList
        } else if appState.browser.isSearching {
            centered { ProgressView("Searching…") }
        } else if let error = appState.browser.error {
            centered {
                statusLabel(error, systemImage: "exclamationmark.triangle", color: .red)
            }
        } else if appState.browser.hasSearched {
            centered {
                statusLabel("No messages match your search.", systemImage: "tray", color: .secondary)
            }
        } else {
            centered {
                statusLabel(
                    "Search your mailbox to find a message.",
                    systemImage: "magnifyingglass",
                    color: .secondary
                )
            }
        }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            resultCountBar
            Divider()
            rowActionStatus
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.browser.results) { message in
                        MailboxBrowserRow(
                            message: message,
                            sourceMailbox: appState.browser.resultQuery?.mailbox,
                            isSelected: appState.browser.selectedMessageIDs.contains(message.id),
                            onToggleSelection: { appState.browser.toggleSelection(message.id) },
                            onPreviewBody: { message, mailbox in
                                previewBody(for: message, mailbox: mailbox)
                            },
                            onGenerateDraft: { message, mailbox in
                                generateDraft(for: message, mailbox: mailbox)
                            }
                        )
                        Divider()
                    }
                    loadMoreFooter
                }
            }
        }
    }

    private var resultCountBar: some View {
        HStack(spacing: 10) {
            Text("Showing \(appState.browser.results.count) of \(appState.browser.totalMatches)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.browser.hasSelection {
                Text("· \(appState.browser.selectedMessages.count) checked")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Button("Clear") { appState.browser.clearSelection() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            if !appState.browser.results.isEmpty && !appState.browser.areAllLoadedSelected {
                Button("Check all \(appState.browser.results.count) listed") {
                    appState.browser.selectAllLoaded()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var rowActionStatus: some View {
        if appState.isGeneratingDraft || appState.bodyError != nil || appState.draftError != nil {
            VStack(alignment: .leading, spacing: 6) {
                if appState.isGeneratingDraft {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Drafting a reply…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = appState.bodyError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let error = appState.draftError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            Divider()
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if appState.browser.error != nil || appState.browser.isLoadingMore || appState.browser.hasMore {
            VStack(spacing: 6) {
                if let error = appState.browser.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if appState.browser.isLoadingMore {
                    ProgressView().controlSize(.small)
                } else if appState.browser.hasMore {
                    Button("Load more") {
                        Task { await appState.loadMoreMailboxResults() }
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Helpers

    private func runSearch() {
        Task { await appState.runMailboxSearch() }
    }

    private func previewBody(for message: MailMessage, mailbox: Mailbox) {
        Task {
            if let preview = await appState.previewBody(for: message, mailbox: mailbox) {
                openedBody = preview
            }
        }
    }

    private func generateDraft(for message: MailMessage, mailbox: Mailbox) {
        Task {
            if let draft = await appState.generateDraft(for: message, mailbox: mailbox) {
                generatedDraft = draft
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusLabel(_ text: String, systemImage: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(color)
        }
        .padding()
    }
}

/// One result row: the message summary plus View body / Draft reply actions,
/// reusing the same `AppState` preview/draft actions as Settings.
private struct MailboxBrowserRow: View {
    let message: MailMessage
    let sourceMailbox: Mailbox?
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onPreviewBody: (MailMessage, Mailbox) -> Void
    let onGenerateDraft: (MailMessage, Mailbox) -> Void
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            // Checking rows narrows cleanup to exactly these messages instead of
            // the whole filter (item 47).
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggleSelection() }))
                .labelsHidden()
                .accessibilityLabel("Select message from \(message.from?.email ?? "unknown sender")")

            VStack(alignment: .leading, spacing: 2) {
                Text(MIMEEncodedWord.displaySubject(message.subject))
                    .font(.callout)
                    .lineLimit(1)
                Text(message.from?.email ?? "unknown sender")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                guard let sourceMailbox else { return }
                onPreviewBody(message, sourceMailbox)
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.borderless)
            .help("View body")
            .disabled(sourceMailbox == nil || appState.isFetchingBody)
            .accessibilityLabel("View body")

            Button {
                guard let sourceMailbox, canDraftReply else { return }
                onGenerateDraft(message, sourceMailbox)
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
            }
            .buttonStyle(.borderless)
            .help(canDraftReply ? "Draft reply" : "Draft reply is unavailable for this folder")
            .disabled(!canDraftReply || appState.isGeneratingDraft || !appState.canGenerateDraft)
            .accessibilityLabel("Draft reply")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canDraftReply: Bool {
        sourceMailbox?.supportsReplyDrafting == true
    }
}
