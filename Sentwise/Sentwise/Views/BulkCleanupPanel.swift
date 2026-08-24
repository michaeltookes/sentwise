import SentwiseMail
import SwiftUI

/// The bulk-cleanup panel inside the mailbox browser (item 42).
///
/// Two scopes, and which one is live is always stated up front:
///
/// - **Checked rows** (item 47): if any row is checked, the action applies to
///   exactly those messages. No preview scan is needed — the user is looking at
///   what they picked.
/// - **Whole filter**: with nothing checked, **Preview** scans every match and
///   only then does a run button appear.
///
/// Destructive actions additionally require confirming an alert that names the
/// scope and count, so mail is never moved on a single mis-click.
struct BulkCleanupPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionRow
            if !hasCheckedRows, let preview = appState.bulk.preview {
                previewSummary(preview)
            }
            statusRow
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .alert("Confirm cleanup", isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) {}
            Button(appState.bulk.action.verb, role: destructiveRole) {
                Task { await run() }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    /// Whether the user has narrowed cleanup to specific rows.
    private var hasCheckedRows: Bool {
        appState.browser.hasSelection
    }

    private var checkedCount: Int {
        appState.browser.selectedMessages.count
    }

    /// Routes to the checked-rows path (single pass on the picked UIDs) or the
    /// filter path. On the filter path a move action sweeps until the mailbox is
    /// clear; mark read is a single pass (it removes nothing, so looping past the
    /// provider's visibility cap is impossible).
    private func run() async {
        if hasCheckedRows {
            await runCheckedRows()
        } else if appState.bulk.action.destination != nil {
            await appState.applyBulkCleanupSweep()
        } else {
            await appState.applyBulkCleanup()
        }
    }

    private func runCheckedRows() async {
        guard !appState.bulkSelectionArchiveUnavailable else { return }
        await appState.applyBulkCleanupToSelectedMessages()
    }

    private func start() {
        if appState.bulk.action.isDestructive {
            isConfirming = true
        } else {
            Task { await run() }
        }
    }

    // MARK: - Controls

    private var actionRow: some View {
        HStack(spacing: 8) {
            Picker("Cleanup", selection: $appState.bulk.action) {
                Text("Mark read").tag(MailBulkAction.markRead)
                Text("Archive").tag(MailBulkAction.archive)
                Text("Move to Trash").tag(MailBulkAction.moveToTrash)
            }
            .labelsHidden()
            .frame(width: 160)
            .disabled(isBusy)

            if hasCheckedRows {
                // Checked rows are their own preview, so act directly.
                Button("\(appState.bulk.action.verb) \(checkedCount) checked") { start() }
                    .disabled(isBusy || appState.bulkSelectionArchiveUnavailable)
                    .help(checkedRowsHelpText)
            } else {
                Button("Preview cleanup") {
                    Task { await appState.previewBulkCleanup() }
                }
                .disabled(isBusy)
                .help("Count every message the current filter matches, without changing anything")

                if appState.canApplyBulkCleanup {
                    Button(appState.bulk.action.verb) { start() }
                        .keyboardShortcut(.none)
                        .help("Apply to every message the preview matched")
                }
            }

            Text(scopeCaption)
                .font(.caption2)
                .foregroundStyle(hasCheckedRows ? .primary : .secondary)

            Spacer()
        }
    }

    /// States which scope is live *before* anything runs — the whole point of the
    /// checkbox feature is that "just these three" is distinguishable from "all
    /// 605 matches", and that has to be readable at a glance.
    private var scopeCaption: String {
        if hasCheckedRows {
            if appState.bulkSelectionArchiveUnavailable {
                return AppState.bulkArchiveUnavailableMessage
            }
            let noun = checkedCount == 1 ? "message" : "messages"
            return "Applies to \(checkedCount) checked \(noun) only"
        }
        return "Applies to all matches, not just the rows listed below"
    }

    @ViewBuilder
    private func previewSummary(_ preview: MailBulkPreview) -> some View {
        if preview.matchCount == 0 {
            Text("Nothing matches that filter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryText(preview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(preview.sample.prefix(3)) { message in
                    Text("• \(message.from?.email ?? "unknown") — \(displaySubject(message))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if preview.sample.count > 3 {
                    Text("…and \(preview.matchCount - 3) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if appState.bulk.isSweeping {
            HStack(spacing: 8) {
                label(sweepText, showsSpinner: true)
                Button("Stop") { appState.cancelBulkCleanup() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else if appState.bulk.isPreviewing {
            label("Scanning mailbox…", showsSpinner: true)
        } else if appState.bulk.isApplying {
            label(progressText, showsSpinner: true)
        } else if let message = appState.bulk.completionMessage {
            Text(message).font(.caption).foregroundStyle(.green)
        }

        if let error = appState.bulk.error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    /// Sweep progress is an ever-growing count, not N-of-M: the true total is
    /// unknown until the mailbox stops revealing older matches (item 49).
    private var sweepText: String {
        let moved = appState.bulk.sweepMovedSoFar ?? 0
        if appState.bulk.isCancellingSweep {
            return "Stopping after the current pass finishes — \(moved) moved so far…"
        }
        return "Cleaning your mailbox — \(moved) moved so far "
            + "(att.net shows 10,000 at a time)…"
    }

    private func label(_ text: String, showsSpinner: Bool) -> some View {
        HStack(spacing: 6) {
            if showsSpinner { ProgressView().controlSize(.small) }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var isBusy: Bool {
        appState.bulk.isPreviewing || appState.bulk.isApplying
    }

    private var destructiveRole: ButtonRole? {
        appState.bulk.action == .moveToTrash ? .destructive : nil
    }

    private var checkedRowsHelpText: String {
        appState.bulkSelectionArchiveUnavailable
            ? AppState.bulkArchiveUnavailableMessage
            : "Apply to only the messages you checked"
    }

    private var progressText: String {
        guard let progress = appState.bulk.progress, progress.total > 0 else {
            return "Working…"
        }
        return "\(appState.bulk.action.verb): \(progress.processed) of \(progress.total)…"
    }

    private var confirmationMessage: String {
        // Checked rows are confirmed before being staged as a preview, and their
        // scope is "these specific messages" — not "everything matching".
        if hasCheckedRows {
            return AppState.bulkSelectionConfirmationMessage(
                for: appState.bulk.action,
                count: checkedCount
            )
        }
        guard let preview = appState.bulk.preview else { return "" }
        return AppState.bulkConfirmationMessage(
            for: appState.bulk.action,
            matchCount: preview.matchCount,
            isPartial: preview.isPartial
        )
    }

    private func summaryText(_ preview: MailBulkPreview) -> String {
        let noun = preview.matchCount == 1 ? "message" : "messages"
        let count = preview.isPartial ? "At least \(preview.matchCount)" : "\(preview.matchCount)"
        let action = appState.bulk.previewAction ?? appState.bulk.action
        let qualifier = action == .markRead ? "unread " : ""
        // Spell out that the scope is the whole match set rather than the page
        // of rows visible below, which shows only the first 25.
        let loaded = appState.browser.results.count
        let scope = loaded > 0 && preview.matchCount > loaded
            ? " — \(action.verb.lowercased()) will apply to all \(preview.matchCount), not just the \(loaded) listed below."
            : " — \(action.verb.lowercased()) will apply to all of them."
        return "\(count) \(qualifier)\(noun) match\(scope)"
    }

    private func displaySubject(_ message: MailMessage) -> String {
        MIMEEncodedWord.displaySubject(message.subject)
    }
}
