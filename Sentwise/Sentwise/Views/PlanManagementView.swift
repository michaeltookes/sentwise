import SwiftUI

/// The in-app plan picker in the Subscription pane's Billing section (backlog
/// item 90). Shows the three purchasable tiers — Starter / Pro / Unlimited — with
/// the account's current tier clearly marked, each with its monthly price and
/// allowance, and an Upgrade/Downgrade affordance on the others. Switching a tier
/// is a prorated Paddle subscription update (not a second checkout), confirmed
/// first, then reconciled against `/v1/me` by `AppState.changePlan(to:)`.
///
/// Billing-only copy throughout — no privacy/retention claims (those are gated and
/// scoped to the BYO-key/local path).
struct PlanManagementView: View {
    @EnvironmentObject var appState: AppState
    /// The tier awaiting confirmation, driving the confirm dialog.
    @State private var pendingTier: PaddlePlan?

    private var currentTier: PaddlePlan? { appState.currentSubscriptionPlanTier }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PaddlePlan.allCases) { tier in
                PlanTierRow(
                    tier: tier,
                    isCurrent: tier == currentTier,
                    isChanging: appState.changingPlanTier == tier,
                    changeDisabled: appState.isChangingPlan || appState.isManagingBilling || !appState.isOnline,
                    upgrade: currentTier.map { tier.isUpgrade(from: $0) } ?? true
                ) {
                    pendingTier = tier
                }
            }

            if let message = appState.planChangeMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(appState.planChangeFailed ? .red : .secondary)
                    .accessibilityIdentifier("planChangeMessage")
            }
        }
        .accessibilityIdentifier("planManagement")
        .confirmationDialog(
            pendingTier.map { appState.changePlanPrompt(for: $0) } ?? "",
            isPresented: Binding(
                get: { pendingTier != nil },
                set: { if !$0 { pendingTier = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let tier = pendingTier {
                Button("Switch to \(tier.displayName)") {
                    let target = tier
                    pendingTier = nil
                    Task { await appState.changePlan(to: target) }
                }
                .accessibilityIdentifier("confirmChangePlan")
            }
            Button("Not now", role: .cancel) { pendingTier = nil }
        }
    }
}

/// One tier card row: name + current/upgrade-downgrade affordance, price, and
/// allowance. Pure presentation — the action is injected.
private struct PlanTierRow: View {
    let tier: PaddlePlan
    let isCurrent: Bool
    let isChanging: Bool
    let changeDisabled: Bool
    let upgrade: Bool
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(tier.displayName)
                    .font(.headline)
                if tier.isFeatured {
                    Text("Most popular")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .accessibilityHidden(true)
                }
                Spacer()
                trailingControl
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(tier.monthlyPrice).font(.title3.weight(.semibold))
                Text("/ month").font(.caption).foregroundStyle(.secondary)
            }

            Text(tier.allowanceSummary)
                .font(.callout)
            Text(tier.allowanceDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25),
                              lineWidth: isCurrent ? 2 : 1)
        )
        .accessibilityIdentifier("planCard_\(tier.rawValue)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isCurrent {
            Text("Current plan")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("planCurrentBadge_\(tier.rawValue)")
        } else if isChanging {
            ProgressView().controlSize(.small)
        } else {
            Button(upgrade ? "Upgrade" : "Downgrade", action: onChange)
                .disabled(changeDisabled)
                .accessibilityIdentifier("changePlanButton_\(tier.rawValue)")
                .accessibilityLabel("\(upgrade ? "Upgrade to" : "Downgrade to") \(tier.displayName)")
        }
    }

    private var accessibilityLabel: String {
        let status = isCurrent ? "Current plan. " : ""
        return "\(tier.displayName). \(status)\(tier.monthlyPrice) per month. \(tier.allowanceSummary)."
    }
}
