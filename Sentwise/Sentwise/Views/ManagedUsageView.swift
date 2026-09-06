import SwiftUI

/// The managed-inference weekly-usage display for the Settings → Subscription
/// pane (backlog items 56b, 73): "N of M drafts used this week · resets
/// <weekday, time>" with a progress bar, a subdued extra-usage line when the user
/// has bought more, a "buy more usage" placeholder (56c wires the purchase), and
/// the own-key valve linking to the AI tab's BYO section (item 59). Hidden
/// gracefully when the quota is unknown. The `/v1/me` refresh is owned by the
/// enclosing Subscription pane's `.task`, so this view does not fetch itself
/// (avoids a double fetch on tab open).
struct ManagedUsageView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let quota = appState.managedQuota {
                usageContent(quota)
            } else {
                Text("Usage will appear once your first draft is counted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("managedUsageUnknown")
            }
        }
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
                    Button("Upgrade for more drafts") {
                        // Open the plan picker so the user can move to a higher tier
                        // (item 56c). The Paddle checkout sheet is hosted by the
                        // enclosing Subscription pane.
                        appState.presentBillingCheckout()
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("buyMoreUsage")
                    .accessibilityLabel("Upgrade for more drafts")
                }

                Button("Need more? Use your own key for unlimited drafting.") {
                    appState.openSettingsHandler?(.ai)
                }
                .buttonStyle(.link)
                .font(.caption2)
                .accessibilityIdentifier("managedOwnKeyValve")
                .accessibilityLabel("Use your own AI key for unlimited drafting")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("managedUsageSection")
    }
}
