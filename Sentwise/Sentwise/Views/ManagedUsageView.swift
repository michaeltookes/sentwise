import SwiftUI

/// The managed-inference monthly-usage display for the Settings → Subscription
/// pane (backlog items 56b, 73): "N of M drafts used this month · resets
/// <month day>" with a progress bar, a subdued extra-usage line when the user
/// has bought more, and a "buy more usage" / upgrade path (56c wires the purchase).
/// The own-key valve was parked 2026-09-16 (item 100) — managed inference is the
/// only shipped path. Hidden gracefully when the quota is unknown. The `/v1/me`
/// refresh is owned by the enclosing Subscription pane's `.task`, so this view does
/// not fetch itself (avoids a double fetch on tab open).
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
                    .accessibilityLabel("Monthly drafts used")
                    .accessibilityValue("\(quota.usedPercent) percent")

                if quota.extraPurchased > 0 {
                    Text("Extra usage purchased: \(quota.extraPurchased)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("managedExtraPurchased")
                }

                if appState.isManagedQuotaExhausted {
                    if appState.hasManageablePaidSubscription {
                        Button("Manage plan") {
                            Task { await appState.openManageBilling() }
                        }
                        .buttonStyle(.link)
                        .disabled(!appState.canManageBilling)
                        .accessibilityIdentifier("buyMoreUsage")
                        .accessibilityLabel("Manage plan")
                    } else if appState.shouldOfferSubscribe {
                        Button("Upgrade for more drafts") {
                            appState.presentBillingCheckout()
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("buyMoreUsage")
                        .accessibilityLabel("Upgrade for more drafts")
                    }
                }
                // The own-key "valve" was parked 2026-09-16 (item 100): managed
                // inference is the only shipped path, so there is nowhere to point it.
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("managedUsageSection")
    }
}
