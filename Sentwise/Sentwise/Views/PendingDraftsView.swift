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
    @ObservedObject private var selection: ReviewWindowSelection

    /// Which tab of the review window is showing.
    enum ReviewTab { case drafts, skipped }

    init(initialTab: ReviewTab = .drafts, selection: ReviewWindowSelection? = nil) {
        _selection = ObservedObject(wrappedValue: selection ?? ReviewWindowSelection(selectedTab: initialTab))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            Divider()

            if appState.notificationsBlocked {
                notificationsOffBanner
            }

            if let error = appState.approvalError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            switch selection.selectedTab {
            case .drafts:
                draftsTab
            case .skipped:
                SkippedMessagesTab(selection: selection)
                    .environmentObject(appState)
            }
        }
        .frame(width: 720, height: 540)
        .task { await appState.refreshNotificationPermission() }
    }

    /// The "notifications are off" hint (item 78). Because the notification is now
    /// just an alert-to-open (item 79), this window is the real approval surface —
    /// the banner reassures the user they can review here regardless, and offers a
    /// one-click path to re-enable notifications. Shown only while off.
    private var notificationsOffBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are off")
                    .font(.caption.weight(.semibold))
                Text("You won't be alerted when drafts are ready — review them here anytime.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Turn On…") { appState.openNotificationSystemSettings() }
                .accessibilityIdentifier("enableNotifications")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    /// The Drafts tab (item 82): a scrollable list of compact rows. Collapsed rows
    /// carry no inner scroll region, so the outer `ScrollView` is the only scroll
    /// surface and scrolls from anywhere in the list. Clicking a row expands the
    /// full `PendingDraftCard` detail inline; only one row is expanded at a time
    /// (`ReviewWindowSelection.expandedDraftIdentity`). The single expanded card
    /// still contains inner scroll (incoming body / reply editor) — acceptable,
    /// because there is only ever one and it is what the user is reading.
    @ViewBuilder
    private var draftsTab: some View {
        if appState.pendingDrafts.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(appState.pendingDrafts, id: \.identity) { draft in
                        let isExpanded = selection.expandedDraftIdentity == draft.identity
                        VStack(spacing: 0) {
                            PendingDraftRow(draft: draft, isExpanded: isExpanded) {
                                selection.toggleExpanded(draft.identity)
                            }
                            if isExpanded {
                                PendingDraftCard(draft: draft)
                                    .environmentObject(appState)
                                    .padding(.top, 4)
                            }
                        }
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
            if selection.selectedTab == .drafts {
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
        let isSelected = selection.selectedTab == tab
        return Button {
            selection.selectedTab = tab
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

final class ReviewWindowSelection: ObservableObject {
    @Published var selectedTab: PendingDraftsView.ReviewTab

    /// The identity of the single pending draft whose detail is expanded inline in
    /// the Drafts tab (item 82). `nil` means every row is collapsed. Because it is
    /// a single value, at most one row can be open at a time — the accordion
    /// behaviour is automatic.
    @Published var expandedDraftIdentity: String?

    init(selectedTab: PendingDraftsView.ReviewTab = .drafts) {
        self.selectedTab = selectedTab
    }

    func selectDraftsAfterSuccessfulOverride(_ didCreateDraft: Bool) {
        guard didCreateDraft else { return }
        selectedTab = .drafts
    }

    /// Toggles the expanded state of one draft row (item 82). Expanding a row
    /// collapses any previously expanded one (single-value accordion); toggling
    /// the already-expanded row collapses it.
    func toggleExpanded(_ identity: String) {
        expandedDraftIdentity = (expandedDraftIdentity == identity) ? nil : identity
    }
}
