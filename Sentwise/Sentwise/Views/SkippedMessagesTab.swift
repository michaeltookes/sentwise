import SwiftUI

/// The "Skipped" tab of the review window (item 69): the log of messages the
/// reply-worthiness gate passed over (item 17), each with a "Draft anyway"
/// override and a dismiss, plus a Clear-all action. Split out of
/// `PendingDraftsView` so the drafts queue and the skip log each own their tab.
/// The full activity history (item 21) will eventually replace this surface.
struct SkippedMessagesTab: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var selection: ReviewWindowSelection

    @ViewBuilder
    var body: some View {
        let skippedMessages = appState.reviewSkippedMessages
        if skippedMessages.isEmpty {
            emptyState
        } else {
            let filtered = skippedMessages.filter {
                ReviewDraftsFilter.matches($0, query: selection.searchQuery, account: selection.accountScope)
            }
            if filtered.isEmpty {
                noMatchesState
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Messages the watcher passed over")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { appState.dismissReviewSkippedMessages(filtered) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filtered) { entry in
                                SkippedMessageRow(entry: entry, selection: selection)
                                    .environmentObject(appState)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "nosign")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing skipped")
                .foregroundStyle(.secondary)
            Text("Messages the watcher decides not to reply to appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when a non-empty search matches no skipped messages (item 76) —
    /// distinct from the "Nothing skipped" empty state.
    private var noMatchesState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No matches")
                .foregroundStyle(.secondary)
            Text(PendingDraftsView.noMatchesDetail(
                searchQuery: selection.searchQuery,
                mailbox: selection.accountScope.mailbox,
                noun: "skipped messages"
            ))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("reviewSkippedNoMatches")
    }
}

/// One skipped-message row: sender, subject, skip reason, and the override
/// ("Draft anyway") plus a dismiss. Deliberately compact — this is the minimal
/// skip-log surface pending the full activity history (item 21). The subject is
/// decoded from RFC 2047 encoded-words for display (item 69).
struct SkippedMessageRow: View {
    let entry: SkippedMessage
    @ObservedObject var selection: ReviewWindowSelection
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
                    if let mailboxBadgeText {
                        Text(mailboxBadgeText)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(subjectText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabelText)
            Spacer()
            if isDrafting {
                ProgressView().controlSize(.small)
            } else {
                Button("Draft anyway") {
                    isDrafting = true
                    Task { @MainActor in
                        let didCreateDraft = await appState.forceDraftSkippedMessage(entry)
                        selection.selectDraftsAfterSuccessfulOverride(didCreateDraft)
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

    private var subjectText: String {
        MIMEEncodedWord.displaySubject(entry.subject)
    }

    var mailboxBadgeText: String? {
        let account = entry.account.trimmingCharacters(in: .whitespacesAndNewlines)
        return account.isEmpty ? nil : account
    }

    var accessibilityLabelText: String {
        let mailboxText = mailboxBadgeText.map { ", mailbox \($0)" } ?? ""
        return "Skipped message from \(entry.senderDisplay)\(mailboxText), \(entry.reason.headline), \(subjectText)"
    }
}
