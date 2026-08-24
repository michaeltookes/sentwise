import SwiftUI

/// The review window for watcher-produced drafts awaiting approval (item 69).
///
/// Two tabs: **Drafts** lists each reviewable pending draft (incoming message
/// beside the proposed reply, with Approve / Deny), and **Skipped** holds the
/// skip log the reply-worthiness gate produced (item 17). Splitting them keeps
/// the drafts queue — the primary approve/deny surface — uncluttered. The card
/// and the skip-log row live in `PendingDraftCard.swift` and
/// `SkippedMessagesTab.swift`.
struct PendingDraftsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: ReviewTab

    /// Which tab of the review window is showing.
    enum ReviewTab { case drafts, skipped }

    init(initialTab: ReviewTab = .drafts) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            Divider()

            if let error = appState.approvalError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            switch selectedTab {
            case .drafts:
                draftsTab
            case .skipped:
                SkippedMessagesTab()
                    .environmentObject(appState)
            }
        }
        .frame(width: 720, height: 540)
    }

    @ViewBuilder
    private var draftsTab: some View {
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
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Review Drafts")
                .font(.headline)
            Spacer()
            if selectedTab == .drafts {
                Label("Approve will \(appState.approveActionLabel.lowercased())", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// The Drafts / Skipped switch. A read-only tab switch, so it is safe for
    /// Prowl hunts to activate; each tab carries a stable AX identifier
    /// (`reviewDraftsTab` / `reviewSkippedTab`) that does not collide with any
    /// forbidden selector and never reaches an approve/deny/send/draft action.
    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton(title: "Drafts", count: appState.pendingDrafts.count,
                      tab: .drafts, identifier: "reviewDraftsTab")
            tabButton(title: "Skipped", count: appState.skippedMessages.count,
                      tab: .skipped, identifier: "reviewSkippedTab")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func tabButton(title: String, count: Int, tab: ReviewTab, identifier: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isSelected
                            ? Color.accentColor.opacity(0.85)
                            : Color.secondary.opacity(0.2)))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.secondary.opacity(0.15) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
