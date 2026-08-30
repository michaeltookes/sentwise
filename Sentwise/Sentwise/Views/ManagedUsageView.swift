import SwiftUI

/// The managed-inference weekly-usage display for the Settings → AI Provider pane
/// (backlog item 56b): "N of M drafts used this week · resets <weekday, time>"
/// with a progress bar, a subdued extra-usage line when the user has bought more,
/// a "buy more usage" placeholder (56c wires the purchase), and the own-key valve
/// pointing at the BYO section below (item 59). Hidden gracefully when the quota
/// is unknown. Refreshes from `/v1/me` when the pane appears.
struct ManagedUsageView: View {
    @EnvironmentObject var appState: AppState
    @State private var showBuyMorePlaceholder = false

    var body: some View {
        // The refresh lives on the outer container, not inside the `if let`, so
        // opening the pane fetches `/v1/me` even while the quota is still unknown
        // (the exact case where the display is hidden and needs populating).
        Group {
            if let quota = appState.managedQuota {
                usageContent(quota)
            }
        }
        .task { await appState.refreshManagedQuota() }
    }

    @ViewBuilder
    private func usageContent(_ quota: ManagedQuota) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(quota.usageSummary())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("managedUsageSummary")

                ProgressView(value: quota.usedFraction)
                    .accessibilityIdentifier("managedUsageProgress")
                    .accessibilityLabel("Weekly drafts used")
                    .accessibilityValue("\(quota.usedPercent) percent")

                if quota.extraPurchased > 0 {
                    Text("Extra usage purchased: \(quota.extraPurchased)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("managedExtraPurchased")
                }

                if appState.isManagedQuotaExhausted {
                    Button("Buy more usage") { showBuyMorePlaceholder = true }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("buyMoreUsage")
                        .accessibilityLabel("Buy more usage")
                    if showBuyMorePlaceholder {
                        Text("Buying extra usage is coming soon.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("buyMoreUsagePlaceholderNote")
                    }
                }

                Text("Need more? Use your own key for unlimited drafting — set it up under \u{201C}Use your own AI\u{201D} below.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("managedOwnKeyValve")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("managedUsageSection")
    }
}
