import SwiftUI

/// The "Analytics" tab of Settings (backlog item 84): a **strictly read-only**
/// usage & behavior surface. Two sections:
///
/// 1. **Quota & usage** — the current-window numbers from item-56b metering
///    (`managedQuota`): drafts used / limit / remaining, a subdued tokens caption,
///    the reset time, and the current window's `extraPurchased`. It intentionally
///    shows numbers/text only and links to the Subscription pane for the allowance
///    *bar* (item 73's `ManagedUsageView`) rather than duplicating it.
/// 2. **Drafting quality** — on-device insights computed from the item-83 feedback
///    store via the pure `DraftFeedbackStats` aggregator: one-shot-accept / edited
///    / denied rates, average edit magnitude, the deny-reason code breakdown, and
///    the answered-then-approved count (item 85 signal), for a selectable window.
///
/// The only interactive elements are the Subscription link (a tab switch) and the
/// window picker (a read-only view toggle, like the Review Drafts tab switch);
/// nothing here mutates real state. The `/v1/me` refresh lives on the OUTER
/// container's `.task` (the 56b/73 review-note pattern) so it runs even while the
/// quota is still unknown.
struct AnalyticsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var window: DraftFeedbackWindow = .last7Days

    /// Below this many stored records the insights section shows its empty state
    /// (item 84) — a few actions are needed before rates mean anything.
    private static let minimumRecordsForInsights = 3

    private var usage: AnalyticsQuotaPresentation? {
        AnalyticsQuotaPresentation.make(from: appState.managedQuota)
    }

    private var stats: DraftFeedbackWindowStats {
        DraftFeedbackStats.compute(records: appState.draftFeedbackRecords, window: window)
    }

    var body: some View {
        Form {
            quotaSection
            insightsSection
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("analyticsTab")
        // Single status refresh on tab open — on the OUTER container so it runs
        // even while the quota is unknown (mirrors the Subscription pane / 56b
        // review note). No-ops when signed out or on any transient error.
        .task { await appState.refreshManagedQuota() }
    }

    // MARK: - Quota & usage

    @ViewBuilder
    private var quotaSection: some View {
        Section("Quota & usage") {
            VStack(alignment: .leading, spacing: 8) {
                if let usage {
                    LabeledContent("Drafts used") {
                        Text("\(usage.draftsUsed) of \(usage.limit)")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("analyticsDraftsUsed")
                    }
                    LabeledContent("Remaining this week") {
                        Text("\(usage.remaining)")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("analyticsDraftsRemaining")
                    }
                    if let reset = usage.resetText {
                        Text(reset)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("analyticsResetTime")
                    }
                    Text(usage.tokensCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("analyticsTokensUsed")
                    if let extra = usage.extraPurchasedRow {
                        Text(extra)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("analyticsExtraPurchased")
                    }
                    Button("Manage your plan and usage bar in Subscription") {
                        appState.openSettingsHandler?(.subscription)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier("analyticsOpenSubscription")
                    .accessibilityLabel("Open the Subscription tab to manage your plan and usage")
                } else {
                    Text("Sign in to Sentwise AI to see your weekly usage. It appears here once "
                         + "your first draft is counted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("analyticsQuotaUnavailable")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("analyticsQuotaSection")
        }
    }

    // MARK: - Drafting quality

    @ViewBuilder
    private var insightsSection: some View {
        Section("Drafting quality") {
            if appState.draftFeedbackRecords.count < Self.minimumRecordsForInsights {
                Text("Sentwise learns from every approve, edit, and deny — check back after "
                     + "you've handled a few drafts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("analyticsEmptyState")
            } else {
                insightsContent
            }
        }
    }

    @ViewBuilder
    private var insightsContent: some View {
        let stats = stats
        VStack(alignment: .leading, spacing: 12) {
            Picker("Window", selection: $window) {
                ForEach(DraftFeedbackWindow.allCases) { window in
                    Text(window.displayTitle).tag(window)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("analyticsWindowPicker")
            .accessibilityLabel("Insights time window")

            Text("Based on \(stats.decidedCount) decided drafts (approved or denied).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("analyticsDecidedCount")

            rateRow("Approved in one shot", rate: stats.oneShotAcceptRate,
                    identifier: "analyticsOneShotRate")
            rateRow("Approved after edits", rate: stats.editedRate,
                    identifier: "analyticsEditRate")
            rateRow("Denied", rate: stats.deniedRate,
                    identifier: "analyticsDeniedRate")

            Divider()

            LabeledContent("Average edit size") {
                Text(editMagnitudeText(stats.averageEditMagnitude))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("analyticsAvgEditMagnitude")
            }
            LabeledContent("Answered a question, then approved") {
                Text("\(stats.answeredThenApprovedCount)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("analyticsAnsweredCount")
            }

            denyReasonBreakdown(stats.denyReasonCounts)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analyticsInsightsSection")
    }

    @ViewBuilder
    private func denyReasonBreakdown(_ counts: [DenyReasonCode: Int]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why drafts were denied")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            ForEach(DenyReasonCode.presetsInDisplayOrder, id: \.self) { code in
                LabeledContent(code.displayTitle) {
                    Text("\(counts[code] ?? 0)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                // Codes only — the deny "Other" free text is never surfaced here.
                .accessibilityIdentifier("analyticsDeniedReason-\(code.rawValue)")
            }
        }
    }

    // MARK: - Row helpers

    /// A labeled rate as a simple capsule/progress bar plus a percentage — native,
    /// no charting dependency.
    @ViewBuilder
    private func rateRow(_ title: String, rate: Double, identifier: String) -> some View {
        let percent = Int((rate * 100).rounded())
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(percent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: rate)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        .accessibilityValue("\(percent) percent")
    }

    private func editMagnitudeText(_ magnitude: Double?) -> String {
        guard let magnitude else { return "No edited approvals yet" }
        return "\(Int((magnitude * 100).rounded()))% of the draft, on average"
    }
}
