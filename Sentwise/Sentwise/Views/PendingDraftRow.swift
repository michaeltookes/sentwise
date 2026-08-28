import SwiftUI

/// The status a pending draft row shows as a chip in the collapsed Drafts list
/// (item 82). Derived from the draft with a pure function so the mapping is
/// unit-testable independently of the view. Only the three at-a-glance states a
/// user acts on live here; transient states (auto-send countdown, offline queue,
/// stale-thread warning) surface inside the expanded detail card, not the chip.
enum PendingDraftRowStatus: Equatable {
    /// The draft is ready to approve as-is.
    case ready
    /// The assistant needs input, or a model-declined draft still has no body.
    case needsInfo
    /// An authored follow-up (item 51) still needs at least one recipient.
    case addRecipients

    /// Maps a draft to its row status. Needs-info takes precedence over the
    /// authored-recipients gate so a flagged authored draft reads as "Needs info".
    static func status(for draft: Draft) -> PendingDraftRowStatus {
        let bodyIsEmpty = draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if draft.needsInfo != nil || (draft.notReplyWorthy != nil && bodyIsEmpty) {
            return .needsInfo
        }
        if draft.isAuthored && !draft.hasAuthoredRecipients {
            return .addRecipients
        }
        return .ready
    }

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .needsInfo: return "Needs info"
        case .addRecipients: return "Add recipients"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .needsInfo: return "exclamationmark.bubble.fill"
        case .addRecipients: return "person.crop.circle.badge.plus"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .needsInfo: return .orange
        case .addRecipients: return .accentColor
        }
    }
}

/// A compact, single-height row for one pending draft in the Drafts list (item
/// 82). Shows the sender, the MIME-decoded subject, a status chip, and a
/// disclosure chevron. The whole row is a `.plain` button that toggles the
/// draft's inline expansion. It deliberately contains **no** inner `ScrollView`
/// or `TextEditor`, so the enclosing list scroll never gets captured — that was
/// the bug item 82 fixes. The editable detail lives in `PendingDraftCard`, shown
/// beneath this row only while expanded.
struct PendingDraftRow: View {
    let draft: Draft
    let isExpanded: Bool
    let onToggle: () -> Void

    private var status: PendingDraftRowStatus { .status(for: draft) }

    /// The sender to show. Reply drafts show the incoming sender; authored
    /// follow-ups (item 51) have no inbound sender, so they announce themselves.
    private var senderText: String {
        if draft.isAuthored {
            return "Post-call follow-up"
        }
        if let from = draft.sourceFrom {
            return from.name ?? from.email
        }
        return "Unknown sender"
    }

    /// The subject to show, MIME-decoded for replies (item 69) and verbatim for
    /// authored follow-ups whose subject the user wrote.
    private var subjectText: String {
        if draft.isAuthored {
            return draft.replySubject.isEmpty ? "(no subject)" : draft.replySubject
        }
        return MIMEEncodedWord.displaySubject(draft.sourceSubject)
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(senderText)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subjectText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                statusChip
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(rowBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
        .accessibilityIdentifier("pendingDraftRow")
        .accessibilityLabel("Draft from \(senderText), \(status.label)")
        .accessibilityHint(isExpanded ? "Collapse draft detail" : "Expand draft detail")
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
    }

    private var rowBackground: Color {
        isExpanded
            ? Color.accentColor.opacity(0.08)
            : Color(nsColor: .controlBackgroundColor)
    }

    private var statusChip: some View {
        Label(status.label, systemImage: status.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(status.tint.opacity(0.15)))
            .foregroundStyle(status.tint)
    }
}
