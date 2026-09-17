import SwiftUI

/// The activity-history window (item 21): a newest-first, locally-stored log of
/// what the assistant has done — drafts created, approvals sent/saved, denials,
/// reply-worthiness skips, stale-thread warnings, and send failures. Each entry
/// shows a timestamp, the event kind (with a reason headline for skips and stale
/// warnings), sender, and subject; entries link back to the source message when
/// the account/mailbox still match the connected account. The whole history can
/// be cleared.
struct ActivityHistoryView: View {
    @EnvironmentObject var appState: AppState

    /// Optional kind filter; `nil` shows everything.
    @State private var kindFilter: ActivityEventKind?
    /// The message body opened from a linked entry, shown in a sheet.
    @State private var openedBody: MailBodyPreview?
    /// The entry whose source message is currently being fetched.
    @State private var openingEventID: UUID?
    /// A user-facing message when opening a linked message fails.
    @State private var openError: String?

    private var filteredEvents: [ActivityEvent] {
        guard let kindFilter else { return appState.activityEvents }
        return appState.activityEvents.filter { $0.kind == kindFilter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let openError {
                Label(openError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            if filteredEvents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredEvents) { event in
                            ActivityEventRow(
                                event: event,
                                canOpen: appState.canOpenActivityEvent(event),
                                isOpening: openingEventID == event.id,
                                accountLabel: appState.showsAccountAttribution
                                    ? appState.accountAttributionLabel(forEmail: event.account) : nil,
                                onOpen: { open(event) }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 640, height: 520)
        .sheet(item: $openedBody) { preview in
            MessageBodyView(preview: preview)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Activity")
                .font(.headline)
            if !appState.activityEvents.isEmpty {
                Text("\(appState.activityEvents.count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }
            Spacer()
            Picker("Filter", selection: $kindFilter) {
                Text("All").tag(ActivityEventKind?.none)
                ForEach(ActivityEventKind.allCases, id: \.self) { kind in
                    Text(kind.headline).tag(ActivityEventKind?.some(kind))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .disabled(appState.activityEvents.isEmpty)
            Button("Clear History") {
                appState.clearActivityHistory()
                kindFilter = nil
            }
            .disabled(appState.activityEvents.isEmpty)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No activity yet")
                .foregroundStyle(.secondary)
            Text("Drafts, approvals, skips, and other actions appear here as they happen.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func open(_ event: ActivityEvent) {
        guard openingEventID == nil else { return }
        openError = nil
        openingEventID = event.id
        Task {
            let preview = await appState.openActivityEvent(event)
            openingEventID = nil
            if let preview {
                openedBody = preview
            } else if let error = appState.bodyError {
                openError = error
            } else {
                openError = "That message is no longer available to open."
            }
        }
    }
}

/// One activity-history entry: kind icon, kind headline with an optional reason
/// badge, sender and subject, a timestamp, and a "View message" link when the
/// source message can still be opened.
private struct ActivityEventRow: View {
    let event: ActivityEvent
    let canOpen: Bool
    let isOpening: Bool
    /// The mailbox this event belongs to, when more than one account is connected
    /// (item 99); nil hides the badge.
    var accountLabel: String?
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.kind.headline)
                        .font(.caption.weight(.semibold))
                    if let reason = event.reasonHeadline {
                        Text(reason)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(event.senderDisplay)
                    .font(.caption)
                    .lineLimit(1)
                Text(event.subjectDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let accountLabel {
                    Label(accountLabel, systemImage: "tray.full")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("activityAccountBadge")
                }
                if let detail = event.activityHistoryVisibleDetail, event.kind.showsFailureDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if let detail = event.activityHistoryVisibleDetail, event.kind.showsSuccessDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if canOpen {
                    if isOpening {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("View message", action: onOpen)
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(event.activityHistoryAccessibilityLabel)
    }
}
