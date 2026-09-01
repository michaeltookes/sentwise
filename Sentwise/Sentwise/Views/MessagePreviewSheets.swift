import SwiftUI

/// A sheet showing the readable body text of a fetched message. Shared by the
/// Settings "Recent messages" section and the mailbox browser (item 40).
struct MessageBodyView: View {
    let preview: MailBodyPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(MIMEEncodedWord.displaySubject(preview.subject))
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            ScrollView {
                Text(preview.text.isEmpty ? "(no text content)" : preview.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 480, height: 420)
    }
}

/// A sheet showing a generated reply draft, with a send/save action reflecting
/// the current `SendBehavior`. Shared by Settings and the mailbox browser.
struct DraftView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var displayedDraft: Draft
    @State private var editedBody: String
    @State private var isDispatching = false
    @State private var dispatchConfirmation: String?
    @State private var dispatchError: String?
    @State private var staleReason: StaleThreadReason?
    @State private var staleApprovalSendBehavior: SendBehavior?
    @State private var countdownRemaining: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var hasRecordedTerminalFeedback = false
    @State private var deferredPreviewAbandonmentDraft: Draft?

    init(draft: Draft) {
        _displayedDraft = State(initialValue: draft)
        _editedBody = State(initialValue: draft.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MIMEEncodedWord.displaySubject(displayedDraft.replySubject))
                        .font(.headline)
                        .lineLimit(2)
                    if let recipient = displayedDraft.sourceReplyTo?.email ?? displayedDraft.sourceFrom?.email {
                        Text("To: \(recipient)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            if let needsInfo = displayedDraft.needsInfo {
                ScrollView {
                    DraftNeedsInfoView(needsInfo: needsInfo)
                        .padding()
                }
            } else {
                if let notReplyWorthy = displayedDraft.notReplyWorthy {
                    ScrollView {
                        DraftNotReplyWorthyView(notReplyWorthy: notReplyWorthy)
                            .padding()
                    }
                    .frame(maxHeight: 150)
                }
                editableReplyBody
            }
            Divider()
            HStack {
                if let confirmation = dispatchConfirmation {
                    Label(confirmation, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let error = dispatchError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                // Needs-info drafts have no safe reply to send. A model-declined
                // draft can be dispatched only after the user writes a body.
                if canOfferDispatchAction {
                    if let remaining = countdownRemaining {
                        countdownControls(remaining)
                    } else {
                        // The button reads "Approve" (item 79); the caption beside
                        // it conveys whether that saves to drafts or sends.
                        Text(approveBehaviorCaption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            dispatchOrStartCountdown()
                        } label: {
                            if isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Approve")
                            }
                        }
                        .disabled(isBusy || isDone || dispatchNeedsBody)
                    }
                }
            }
            .padding()
        }
        .frame(width: 480, height: 460)
        .onDisappear { recordPreviewAbandonmentIfNeeded() }
        .confirmationDialog(
            staleReason?.headline ?? "",
            isPresented: staleWarningBinding,
            titleVisibility: .visible
        ) {
            Button(staleApprovalLabel, role: .destructive) {
                let sendBehavior = staleApprovalSendBehavior ?? appState.sendBehavior
                Task { await approveDisplayedDraft(sendBehavior: sendBehavior, force: true) }
            }
            Button("Regenerate") {
                Task { await regenerateDisplayedDraft() }
            }
            Button("Cancel", role: .cancel) {
                staleReason = nil
                staleApprovalSendBehavior = nil
            }
        } message: {
            if let staleReason {
                Text(staleReason.detail)
            }
        }
    }

    private var staleWarningBinding: Binding<Bool> {
        Binding(
            get: { staleReason != nil },
            set: {
                if !$0 {
                    staleReason = nil
                    staleApprovalSendBehavior = nil
                }
            }
        )
    }

    private var staleApprovalLabel: String {
        "Approve anyway"
    }

    /// Caption beside the Approve button conveying the send behavior (item 79).
    private var approveBehaviorCaption: String {
        appState.sendBehavior == .autoSend ? "Approve will send now" : "Approve will save to Drafts"
    }

    private var hasEditedReplyBody: Bool {
        !editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canOfferDispatchAction: Bool {
        displayedDraft.needsInfo == nil
    }

    private var dispatchNeedsBody: Bool {
        displayedDraft.notReplyWorthy != nil && !hasEditedReplyBody
    }

    private var editableReplyBody: some View {
        TextEditor(text: $editedBody)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .disabled(isBusy)
            .accessibilityLabel("Reply body")
    }

    /// The auto-send safety-net controls (item 23) shown in place of the dispatch
    /// button while a preview send is counting down.
    private func countdownControls(_ remaining: Int) -> some View {
        HStack(spacing: 8) {
            Text("Sending in \(remaining)s…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { cancelPreviewCountdown() }
                .accessibilityLabel("Cancel send")
        }
    }

    /// Starts the auto-send countdown for a preview send when the safety net is
    /// enabled (item 23); otherwise dispatches immediately (today's behavior).
    /// Save-as-draft and instant mode never wait.
    private func dispatchOrStartCountdown() {
        let approvalSendBehavior = appState.sendBehavior
        guard approvalSendBehavior == .autoSend, appState.sendDelaySeconds > 0 else {
            Task { await approveDisplayedDraft(sendBehavior: approvalSendBehavior) }
            return
        }
        startPreviewCountdown(sendBehavior: approvalSendBehavior)
    }

    private func startPreviewCountdown(sendBehavior approvalSendBehavior: SendBehavior) {
        cancelPreviewCountdown(recordActivity: false)
        dispatchError = nil
        dispatchConfirmation = nil
        let seconds = max(appState.sendDelaySeconds, 1)
        countdownRemaining = seconds
        countdownTask = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: appState.sendCountdownTickNanoseconds)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                remaining -= 1
                countdownRemaining = remaining
            }
            if Task.isCancelled { return }
            countdownRemaining = nil
            countdownTask = nil
            // The stale re-check runs inside `approveDraftPreview`, so it happens at
            // the end of the window, immediately before dispatch (item 23 pairs with
            // item 12).
            await approveDisplayedDraft(sendBehavior: approvalSendBehavior)
        }
    }

    private func cancelPreviewCountdown(recordActivity: Bool = true) {
        let hadCountdown = countdownTask != nil || countdownRemaining != nil
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
        guard recordActivity, hadCountdown else { return }
        displayedDraft.applyEditedBody(editedBody)
        appState.recordDraftPreviewSendCancellation(for: displayedDraft)
    }

    private func approveDisplayedDraft(sendBehavior approvalSendBehavior: SendBehavior, force: Bool = false) async {
        guard !isDispatching else { return }
        dispatchConfirmation = nil
        dispatchError = nil
        isDispatching = true
        defer { isDispatching = false }

        // Fold the user's inline edit (item 19) into the draft so the edited body
        // is exactly what dispatches, retaining the assistant's original for
        // future voice tuning.
        displayedDraft.applyEditedBody(editedBody)

        do {
            staleApprovalSendBehavior = approvalSendBehavior
            dispatchConfirmation = try await appState.approveDraftPreview(
                displayedDraft,
                sendBehavior: approvalSendBehavior,
                force: force
            )
            hasRecordedTerminalFeedback = true
            deferredPreviewAbandonmentDraft = nil
            staleReason = nil
            staleApprovalSendBehavior = nil
        } catch let error as DraftDispatchError {
            if case .staleThread(let reason) = error {
                staleReason = reason
            } else {
                dispatchError = AppState.draftMessage(for: error)
                staleApprovalSendBehavior = nil
            }
            recordDeferredPreviewAbandonmentIfNeeded()
        } catch {
            dispatchError = AppState.draftMessage(for: error)
            staleApprovalSendBehavior = nil
            recordDeferredPreviewAbandonmentIfNeeded()
        }
    }

    private func regenerateDisplayedDraft() async {
        guard !isDispatching else { return }
        dispatchConfirmation = nil
        dispatchError = nil
        staleReason = nil
        staleApprovalSendBehavior = nil
        isDispatching = true
        defer { isDispatching = false }

        do {
            displayedDraft = try await appState.regenerateDraftPreview(displayedDraft)
            // Regeneration produces a fresh reply; discard the prior inline edit
            // by resyncing the editor to the new body.
            editedBody = displayedDraft.body
        } catch {
            dispatchError = AppState.draftMessage(for: error)
        }
        recordDeferredPreviewAbandonmentIfNeeded()
    }

    private var isBusy: Bool {
        isDispatching
    }

    private var isDone: Bool {
        dispatchConfirmation != nil
    }

    private var shouldRecordPreviewAbandonment: Bool {
        !hasRecordedTerminalFeedback && !isDone && displayedDraft.manualPreview == true
    }

    private func recordPreviewAbandonmentIfNeeded(allowWhileDispatching: Bool = false) {
        cancelPreviewCountdown()
        guard shouldRecordPreviewAbandonment else {
            return
        }
        var abandonedDraft = displayedDraft
        abandonedDraft.applyEditedBody(editedBody)
        guard !isDispatching || allowWhileDispatching else {
            deferredPreviewAbandonmentDraft = abandonedDraft
            return
        }
        appState.recordDraftPreviewAbandonment(for: abandonedDraft)
        hasRecordedTerminalFeedback = true
        deferredPreviewAbandonmentDraft = nil
    }

    private func recordDeferredPreviewAbandonmentIfNeeded() {
        guard let abandonedDraft = deferredPreviewAbandonmentDraft else { return }
        guard !hasRecordedTerminalFeedback else {
            deferredPreviewAbandonmentDraft = nil
            return
        }
        appState.recordDraftPreviewAbandonment(for: abandonedDraft)
        hasRecordedTerminalFeedback = true
        deferredPreviewAbandonmentDraft = nil
    }
}
