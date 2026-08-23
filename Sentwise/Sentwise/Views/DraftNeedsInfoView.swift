import SwiftUI

/// The distinct "needs your input" state shown in place of a reply body when the
/// assistant declined to fabricate one (item 13). Used by both the draft preview
/// sheet and the pending-approval queue so a flagged draft reads the same way
/// everywhere.
struct DraftNeedsInfoView: View {
    let needsInfo: DraftNeedsInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Needs your input", systemImage: "exclamationmark.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text(needsInfo.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !needsInfo.missing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(needsInfo.missing, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(item).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
            }

            Text("Sentwise won't send a reply here — add these details or write the reply yourself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The distinct state shown when the model explicitly says the source message
/// does not need a written reply. Normally the watcher routes this to the skip
/// log; it can still appear if the user chooses "Draft anyway."
struct DraftNotReplyWorthyView: View {
    let notReplyWorthy: DraftNotReplyWorthy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No reply needed", systemImage: "nosign")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(notReplyWorthy.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("Sentwise did not generate a reply here. Write one below before approving.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
