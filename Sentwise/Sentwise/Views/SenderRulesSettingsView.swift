import SwiftUI

/// The "Sender Rules" tab of Settings (item 18): the allowlist of senders to
/// always draft and the blocklist of senders to never draft. Edits are persisted
/// immediately and take effect on the next inbox poll — no restart needed.
struct SenderRulesSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Text(
                    "Choose senders the watcher should always draft, or never draft. "
                    + "Enter a full address (alice@example.com) or a whole domain (example.com). "
                    + "Changes take effect on the next inbox check — no restart needed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if appState.offersAutomaticDrafting {
                automaticDraftingSection
                autoDraftListSection
            } else {
                proFeatureSection
            }

            SenderRuleListSection(
                title: "Always draft (allowlist)",
                placeholder: "alice@example.com or example.com",
                emptyHint: "No allowlisted senders yet.",
                addAccessibilityLabel: "Add sender to allowlist",
                rules: appState.senderAllowlist,
                onAdd: { appState.addAllowedSender($0) },
                onDelete: { appState.removeAllowedSenders(atOffsets: $0) }
            )

            SenderRuleListSection(
                title: "Never draft (blocklist)",
                placeholder: "spammer@example.com or example.com",
                emptyHint: "No blocklisted senders yet.",
                addAccessibilityLabel: "Add sender to blocklist",
                rules: appState.senderBlocklist,
                onAdd: { appState.addBlockedSender($0) },
                onDelete: { appState.removeBlockedSenders(atOffsets: $0) }
            )
        }
        .formStyle(.grouped)
    }

    /// The Starter notice shown where the auto-drafting controls otherwise appear
    /// (item 108): Starter has no inbox watcher at all, so there is nothing to
    /// automate — manual on-demand drafting and transcript follow-ups still work.
    private var proFeatureSection: some View {
        Section("Inbox drafting") {
            Label(AppState.inboxWatchingProFeatureMessage, systemImage: "sparkles")
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("inboxWatchingProFeatureNotice")
            Text(
                "On your plan, Sentwise drafts post-call transcript follow-ups and any reply you "
                + "ask for from Browse — but it doesn't watch your inbox. Upgrade to Pro to have "
                + "reply-worthy mail notify you and draft on request."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The automatic-drafting opt-in (item 108): off by default. When on, a
    /// reply-worthy message is drafted automatically instead of waiting for a
    /// click. The optional monthly cap bounds how much of the allotment
    /// auto-drafting may spend before it falls back to draft-on-click.
    private var automaticDraftingSection: some View {
        Section("Automatic drafting") {
            Toggle("Automatically draft replies", isOn: $appState.inboxDrafting.autoDraftEnabled)
                .accessibilityIdentifier("autoDraftToggle")
            Text(
                "Off by default: reply-worthy mail notifies you and drafts on your click, so a "
                + "credit is spent only when you ask. Turn on to draft every reply-worthy message "
                + "automatically."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("Cap monthly auto-drafts", isOn: budgetEnabledBinding)
                .accessibilityIdentifier("autoDraftBudgetToggle")
            if appState.inboxDrafting.monthlyAutoDraftBudget != nil {
                Stepper(
                    "At most \(appState.inboxDrafting.monthlyAutoDraftBudget ?? 0) auto-drafts / month",
                    value: budgetValueBinding,
                    in: 1...1000
                )
                .accessibilityIdentifier("autoDraftBudgetStepper")
                Text(
                    "Auto-drafting stops at this many drafts each month and falls back to "
                    + "draft-on-click until your allotment resets. Manual and transcript drafts "
                    + "don't count."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The per-sender/domain auto-draft list (item 108): senders drafted
    /// automatically even when the global toggle is off. Reuses item 18's rule UI.
    private var autoDraftListSection: some View {
        SenderRuleListSection(
            title: "Always auto-draft",
            placeholder: "alice@example.com or example.com",
            emptyHint: "No auto-draft senders yet.",
            addAccessibilityLabel: "Add sender to auto-draft list",
            rules: appState.inboxDrafting.autoDraftSenders,
            onAdd: { appState.addAutoDraftSender($0) },
            onDelete: { appState.removeAutoDraftSenders(atOffsets: $0) }
        )
    }

    /// Toggles the monthly cap on/off. Enabling seeds a sensible default; disabling
    /// clears it (uncapped auto-drafting).
    private var budgetEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.inboxDrafting.monthlyAutoDraftBudget != nil },
            set: { isOn in
                appState.inboxDrafting.monthlyAutoDraftBudget = isOn
                    ? (appState.inboxDrafting.monthlyAutoDraftBudget ?? 30)
                    : nil
            }
        )
    }

    /// The cap value, defaulting to 30 while enabled.
    private var budgetValueBinding: Binding<Int> {
        Binding(
            get: { appState.inboxDrafting.monthlyAutoDraftBudget ?? 30 },
            set: { appState.inboxDrafting.monthlyAutoDraftBudget = max(1, $0) }
        )
    }
}

/// One allow/blocklist section: an add field plus the current rules with delete.
private struct SenderRuleListSection: View {
    let title: String
    let placeholder: String
    let emptyHint: String
    let addAccessibilityLabel: String
    let rules: [SenderRule]
    let onAdd: (String) -> Bool
    let onDelete: (IndexSet) -> Void

    @State private var entry = ""

    private var isEntryEmpty: Bool {
        entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section(title) {
            HStack {
                TextField(placeholder, text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityLabel(addAccessibilityLabel)
                Button("Add", action: add)
                    .disabled(isEntryEmpty)
            }

            if rules.isEmpty {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
                .onDelete(perform: onDelete)
            }
        }
    }

    private func ruleRow(_ rule: SenderRule) -> some View {
        HStack {
            Image(systemName: rule.kind == .address ? "person.crop.circle" : "globe")
                .foregroundStyle(.secondary)
            Text(rule.pattern)
            Spacer()
            Text(rule.kindLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rule.kindLabel) rule \(rule.pattern)")
    }

    private func add() {
        guard onAdd(entry) else { return }
        entry = ""
    }
}
