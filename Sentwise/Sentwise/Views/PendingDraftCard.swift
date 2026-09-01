import SwiftUI

/// A single reviewable draft: incoming message on the left, proposed reply on
/// the right, with Approve / Deny actions. Subjects are decoded from RFC 2047
/// encoded-words and the incoming body is normalised for readability (item 69);
/// both are display-only transforms that never mutate the stored draft.
struct PendingDraftCard: View {
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
        draft.needsInfo != nil ? "Answer to re-draft" : (draft.notReplyWorthy != nil ? "Write a reply" : "Proposed reply")
    }

    private var replySubjectDisplayText: String {
        if draft.isAuthored {
            return draft.replySubject.isEmpty ? "(no subject)" : draft.replySubject
        }
        return MIMEEncodedWord.displaySubject(draft.replySubject)
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
        .onChange(of: draft.body) { _, newValue in
            syncEditedBody(with: newValue)
        }
        .onChange(of: draft.needsInfo == nil) { _, isReplyEditorVisible in
            guard isReplyEditorVisible else { return }
            syncEditedBody(with: draft.body)
        }
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
            Text(MIMEEncodedWord.displaySubject(draft.sourceSubject))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            incomingBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var incomingBody: some View {
        ScrollView {
            if let raw = draft.incomingBody, !raw.isEmpty {
                Text(IncomingBodyNormalizer.normalize(raw))
                    .font(.callout)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("(message body unavailable)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: 180)
    }

    @ViewBuilder
    private var replyColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(replyColumnTitle)
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            if draft.needsInfo != nil {
                ScrollView {
                    DraftNeedsInfoAnswerView(draft: draft)
                        .environmentObject(appState)
                }
                .frame(maxHeight: 260)
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
                HStack(spacing: 4) {
                    Text("To:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(recipient)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(recipient)
                }
            }
            Text(replySubjectDisplayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
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
                // Button reads "Approve" (item 79); the window's caption conveys
                // whether that saves to drafts or sends.
                Button("Approve") {
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

    private func syncEditedBody(with body: String) {
        guard editedBody != body else { return }
        editedBody = body
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
                Button("Approve anyway") {
                    Task { await approve(force: true) }
                }
                .disabled(isBusy)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }
}
