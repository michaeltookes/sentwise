import SwiftUI

/// The single-select deny-reason picker (item 83, Phase 1). Presented as a sheet
/// when the user hits Deny/Discard, *before* the deny finalizes: the user picks a
/// preset reason or "Other" (which reveals a mandatory free-text field), and the
/// deny cannot complete until a reason is chosen (and Other has non-empty text).
/// Cancel aborts cleanly — the draft stays queued.
///
/// A per-session "don't ask again" checkbox lets heavy deniers reuse their last
/// reason silently for the rest of the app run.
///
/// **Prowl:** the confirm control (`denyReasonConfirm`) is state-mutating and is
/// forbidden in hunt mode exactly as Deny is; every control carries a stable AX
/// identifier so a hunt can assert the pane where guardrails allow.
struct DenyReasonPicker: View {
    let prompt: DenyReasonPrompt
    @EnvironmentObject var appState: AppState

    @State private var selectedCode: DenyReasonCode
    @State private var otherText: String
    @State private var dontAskAgain: Bool
    @FocusState private var isOtherFocused: Bool

    init(prompt: DenyReasonPrompt) {
        self.prompt = prompt
        _selectedCode = State(initialValue: prompt.defaultCode)
        _otherText = State(initialValue: prompt.defaultOtherText)
        _dontAskAgain = State(initialValue: false)
    }

    private var trimmedOtherText: String {
        otherText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Confirm is enabled once a reason is chosen; "Other" additionally requires
    /// non-empty free text.
    private var canConfirm: Bool {
        selectedCode != .other || !trimmedOtherText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Why deny this draft?")
                    .font(.headline)
                Text("Your reason stays on this Mac and helps Sentwise draft and surface better over time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            reasonOptions
                .accessibilityIdentifier("denyReasonPicker")
                .accessibilityElement(children: .contain)

            if selectedCode == .other {
                otherField
            }

            Toggle("Don't ask again this session", isOn: $dontAskAgain)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("denyDontAskAgain")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    appState.cancelDenyReason()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("denyReasonCancel")

                Button("Deny") {
                    appState.confirmDenyReason(
                        code: selectedCode,
                        otherText: otherText,
                        dontAskAgain: dontAskAgain
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
                .accessibilityIdentifier("denyReasonConfirm")
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var reasonOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(DenyReasonCode.presetsInDisplayOrder, id: \.self) { code in
                reasonRow(code)
            }
        }
    }

    private func reasonRow(_ code: DenyReasonCode) -> some View {
        Button {
            selectedCode = code
            if code == .other {
                isOtherFocused = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedCode == code ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selectedCode == code ? Color.accentColor : Color.secondary)
                Text(code.displayTitle)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("denyReasonOption-\(code.rawValue)")
        .accessibilityAddTraits(selectedCode == code ? [.isSelected] : [])
    }

    private var otherField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tell us why (required)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Your reason", text: $otherText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($isOtherFocused)
                .accessibilityIdentifier("denyReasonOtherField")
                .accessibilityLabel("Deny reason details")
            Text("Stays on this Mac — free text is never shared or logged.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
