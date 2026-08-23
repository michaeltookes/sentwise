import SwiftUI

/// The review window for watcher-produced drafts awaiting approval. Lists each
/// pending draft with the incoming message and the proposed reply side by side,
/// and Approve / Deny actions. Approve sends or saves per the send-behavior
/// setting; Deny discards.
struct PendingDraftsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let error = appState.approvalError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            if appState.pendingDrafts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(appState.pendingDrafts, id: \.identity) { draft in
                            PendingDraftCard(draft: draft)
                                .environmentObject(appState)
                        }
                    }
                    .padding(12)
                }
            }

            if !appState.skippedMessages.isEmpty {
                Divider()
                skippedSection
            }
        }
        .frame(width: 720, height: 520)
    }

    /// A bare-bones list of messages the reply-worthiness gate skipped (item 17),
    /// each with a "Draft anyway" override. The full activity history (item 21)
    /// will replace this; kept minimal deliberately.
    private var skippedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Skipped (\(appState.skippedMessages.count))", systemImage: "nosign")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { appState.dismissAllSkippedMessages() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(appState.skippedMessages) { entry in
                        SkippedMessageRow(entry: entry)
                            .environmentObject(appState)
                    }
                }
            }
            .frame(maxHeight: 132)
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Drafts to review")
                .font(.headline)
            if !appState.pendingDrafts.isEmpty {
                Text("\(appState.pendingDrafts.count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }
            Spacer()
            Label("Approve will \(appState.approveActionLabel.lowercased())", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No drafts waiting")
                .foregroundStyle(.secondary)
            Text("New replies appear here as the watcher drafts them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One skipped-message row: sender, subject, skip reason, and the override
/// ("Draft anyway") plus a dismiss. Deliberately compact — this is the minimal
/// skip-log surface pending the full activity history (item 21).
private struct SkippedMessageRow: View {
    let entry: SkippedMessage
    @EnvironmentObject var appState: AppState
    @State private var isDrafting = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.senderDisplay)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(entry.reason.headline)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundStyle(.secondary)
                }
                Text(entry.subject.isEmpty ? "(no subject)" : entry.subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isDrafting {
                ProgressView().controlSize(.small)
            } else {
                Button("Draft anyway") {
                    isDrafting = true
                    Task {
                        await appState.forceDraftSkippedMessage(entry)
                        isDrafting = false
                    }
                }
                .font(.caption)
                Button {
                    appState.dismissSkippedMessage(entry)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// A single reviewable draft: incoming message on the left, proposed reply on
/// the right, with Approve / Deny actions.
private struct PendingDraftCard: View {
    let draft: Draft
    @EnvironmentObject var appState: AppState
    @State private var editedBody: String
    @State private var editSaveTask: Task<Void, Never>?
    @State private var editPersistRevision = 0
    @FocusState private var isBodyFocused: Bool

    init(draft: Draft) {
        self.draft = draft
        _editedBody = State(initialValue: draft.body)
    }

    private var isBusy: Bool { appState.approvingDraftIDs.contains(draft.identity) }

    private var staleReason: StaleThreadReason? { appState.pendingStaleWarnings[draft.identity] }

    /// Remaining seconds on this draft's auto-send countdown (item 23), if any.
    private var countdownRemaining: Int? { appState.sendCountdownRemaining(for: draft.identity) }

    private var queuedDispatchIntent: OfflineQueuedDraftDispatch? {
        appState.offlineQueuedDispatch[draft.identity]
    }

    private var isQueuedForNetwork: Bool {
        appState.isWaitingForNetwork(draft.identity) || queuedDispatchIntent != nil
    }

    private var hasEditedReplyBody: Bool { !editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canOfferApprovalAction: Bool { draft.needsInfo == nil }
    private var approvalNeedsBody: Bool { draft.notReplyWorthy != nil && !hasEditedReplyBody }

    private var replyColumnTitle: String {
        draft.needsInfo != nil ? "Can't draft this one" : (draft.notReplyWorthy != nil ? "Write a reply" : "Proposed reply")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.isFlagged {
                Label("Needs your input", systemImage: "exclamationmark.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 12) {
                incomingColumn
                Divider()
                replyColumn
            }
            Divider()
            if let countdownRemaining {
                countdownRow(countdownRemaining)
            } else if isQueuedForNetwork {
                waitingForNetworkRow()
            } else if let staleReason {
                staleWarning(staleReason)
            } else {
                actions
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(cardStroke, lineWidth: draft.isFlagged ? 1.5 : 1))
        .onDisappear { persistEditedBodyImmediately() }
    }

    private var cardStroke: Color {
        draft.isFlagged ? Color.orange.opacity(0.5) : Color.secondary.opacity(0.15)
    }

    @ViewBuilder
    private var incomingColumn: some View {
        if draft.isAuthored {
            authoredContextColumn
        } else {
            replyingToColumn
        }
    }

    /// The left column for an authored follow-up (item 51): recipients editor and
    /// a note that it was drafted from a call, in place of an inbound message.
    private var authoredContextColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Post-call follow-up")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            FollowUpRecipientsField(draft: draft)
                .environmentObject(appState)
            Text("Drafted from a call transcript.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var replyingToColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Incoming")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            if let sender = draft.sourceFrom {
                Text(sender.name ?? sender.email)
                    .font(.subheadline).bold()
                if sender.name != nil {
                    Text(sender.email).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(draft.sourceSubject)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(draft.incomingBody ?? "(message body unavailable)")
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var replyColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(replyColumnTitle)
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            if let needsInfo = draft.needsInfo {
                ScrollView {
                    DraftNeedsInfoView(needsInfo: needsInfo)
                }
                .frame(maxHeight: 180)
            } else {
                if let notReplyWorthy = draft.notReplyWorthy {
                    ScrollView {
                        DraftNotReplyWorthyView(notReplyWorthy: notReplyWorthy)
                    }
                    .frame(maxHeight: 90)
                }
                editableReplyFields
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editableReplyFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !draft.isAuthored, let recipient = draft.sourceReplyTo?.email ?? draft.sourceFrom?.email {
                Text("To: \(recipient)").font(.caption).foregroundStyle(.secondary)
            }
            Text(draft.replySubject)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $editedBody)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                .focused($isBodyFocused)
                .disabled(isBusy || isQueuedForNetwork)
                .accessibilityLabel("Reply body")
                .onChange(of: editedBody) { _, newValue in
                    queueEditedBodyPersist(newValue)
                }
                .onChange(of: isBodyFocused) { _, focused in
                    if !focused {
                        persistEditedBodyImmediately()
                    }
                }
                .onChange(of: draft.body) { _, newValue in
                    editedBody = newValue
                }
        }
    }

    private var actions: some View {
        HStack {
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(draft.isFlagged ? "Dismiss" : "Deny", role: .destructive) {
                appState.denyDraft(draft)
            }
            .disabled(isBusy)

            // Needs-info drafts cannot approve; model-declined overrides need a user-written body.
            if canOfferApprovalAction {
                Button(appState.approveActionLabel) {
                    Task { await approve() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || approvalNeedsBody || (draft.isAuthored && !draft.hasAuthoredRecipients))
            }
        }
    }

    /// The auto-send safety-net row (item 23): a live countdown with a Cancel
    /// button. Cancelling returns the draft to the normal pending actions with any
    /// edits intact.
    private func countdownRow(_ remaining: Int) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Sending in \(remaining)s…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Cancel") {
                appState.cancelSendCountdown(draft)
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel send")
        }
    }

    private var queuedDispatchDescription: String {
        switch queuedDispatchIntent?.sendBehavior {
        case .autoSend:
            return "Will send when online."
        case .saveAsDraft:
            return "Will save to Drafts when online."
        case nil:
            return "Will dispatch when online."
        }
    }

    private var cancelQueuedDispatchLabel: String {
        switch queuedDispatchIntent?.sendBehavior {
        case .autoSend:
            return "Cancel queued send"
        case .saveAsDraft:
            return "Cancel queued save"
        case nil:
            return "Cancel queued action"
        }
    }

    private func waitingForNetworkRow() -> some View {
        HStack(spacing: 8) {
            Label("Waiting for network", systemImage: "wifi.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(queuedDispatchDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Discard", role: .destructive) {
                appState.denyDraft(draft)
            }
            .disabled(isBusy)
            Button(cancelQueuedDispatchLabel) {
                appState.cancelQueuedDraftDispatch(draft.identity)
            }
            .disabled(isBusy)
            .accessibilityLabel(cancelQueuedDispatchLabel)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
    }

    private func queueEditedBodyPersist(_ newValue: String) {
        editPersistRevision += 1
        let revision = editPersistRevision
        appState.notePendingDraftBodyEdit(draft, editedBody: newValue)
        editSaveTask?.cancel()
        editSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, editPersistRevision == revision else { return }
            appState.updatePendingDraftBody(draft, to: newValue)
        }
    }

    private func persistEditedBodyImmediately() {
        cancelQueuedEditPersist()
        appState.updatePendingDraftBody(draft, to: editedBody)
    }

    private func cancelQueuedEditPersist() {
        editPersistRevision += 1
        editSaveTask?.cancel()
        editSaveTask = nil
    }

    /// Folds the inline edit into the queued draft (item 19), then approves the
    /// edited draft so the edited body is exactly what sends or saves.
    private func approve(force: Bool = false) async {
        cancelQueuedEditPersist()
        await appState.approvePendingDraft(draft, withEditedBody: editedBody, force: force)
    }

    private func regenerate() async {
        cancelQueuedEditPersist()
        await appState.regeneratePendingDraft(draft)
    }

    /// The conflict warning shown when a draft's thread changed since it was
    /// generated (item 12), offering send-anyway / regenerate / discard.
    private func staleWarning(_ reason: StaleThreadReason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(reason.headline, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(reason.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Discard", role: .destructive) {
                    appState.denyDraft(draft)
                }
                .disabled(isBusy)
                Button("Regenerate") {
                    Task { await regenerate() }
                }
                .disabled(isBusy)
                Button("\(appState.approveActionLabel) anyway") {
                    Task { await approve(force: true) }
                }
                .disabled(isBusy)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }
}
