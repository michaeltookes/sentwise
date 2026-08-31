import SwiftUI

/// The interactive "answer in place" area shown on a `NEEDS_INFO` pending draft
/// card (item 85): one field per missing-info question, a free-text "anything
/// else" field, and a **Re-draft with my answers** action that regenerates the
/// reply with the answers injected. After the loop fails twice a **Write it
/// yourself** escape appears, opening the reply editor seeded with the answers.
///
/// Fields seed from the draft's stored facts so a second `NEEDS_INFO` round keeps
/// everything already typed; answers to earlier questions no longer asked are
/// shown read-only so they are visibly preserved.
struct DraftNeedsInfoAnswerView: View {
    let draft: Draft
    @EnvironmentObject var appState: AppState
    @State private var answers: [String]
    @State private var extra: String

    init(draft: Draft) {
        self.draft = draft
        let missing = draft.needsInfo?.missing ?? []
        let stored = draft.userSuppliedFacts
        _answers = State(initialValue: missing.map { question in
            stored?.answers.first(where: { $0.question == question })?.response ?? ""
        })
        _extra = State(initialValue: stored?.additional ?? "")
    }

    private var needsInfo: DraftNeedsInfo { draft.needsInfo ?? DraftNeedsInfo(summary: "") }
    private var missing: [String] { needsInfo.missing }
    private var isBusy: Bool { appState.approvingDraftIDs.contains(draft.identity) }

    /// Re-draft is enabled once at least one field is non-empty (item 85).
    private var canRedraft: Bool {
        answers.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Answers from earlier rounds whose questions the model is no longer asking —
    /// preserved and shown read-only so the user sees nothing was lost.
    private var preservedPriorAnswers: [UserSuppliedFacts.Answer] {
        guard let stored = draft.userSuppliedFacts else { return [] }
        let current = Set(missing)
        return stored.nonEmptyAnswers.filter { !current.contains($0.question) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !missing.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(missing.enumerated()), id: \.offset) { index, question in
                        answerField(index: index, question: question)
                    }
                }
            }
            extraField
            if !preservedPriorAnswers.isEmpty {
                preservedAnswersSection
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Needs your input", systemImage: "exclamationmark.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(needsInfo.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Answer below and Sentwise will re-draft the reply for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func answerField(index: Int, question: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(question)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            TextField("Your answer", text: binding(for: index), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(isBusy)
                .accessibilityLabel(question)
                .accessibilityIdentifier("needsInfoAnswerField-\(index)")
        }
    }

    private var extraField: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Anything else Sentwise should know")
                .font(.caption.weight(.medium))
            TextField("Optional", text: $extra, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(isBusy)
                .accessibilityLabel("Anything else")
                .accessibilityIdentifier("needsInfoExtraField")
        }
    }

    private var preservedAnswersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You already told Sentwise")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(preservedPriorAnswers.enumerated()), id: \.offset) { _, answer in
                Text("• \(answer.question.isEmpty ? answer.response : "\(answer.question): \(answer.response)")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack {
            if isBusy { ProgressView().controlSize(.small) }
            Spacer()
            if draft.shouldOfferWriteItYourself {
                Button("Write it yourself") {
                    _ = appState.writeReplyYourself(draft, currentRound: currentRound())
                }
                .disabled(isBusy)
                .accessibilityIdentifier("writeItYourself")
            }
            Button("Re-draft with my answers") {
                Task { await appState.redraftPendingDraftWithAnswers(draft, round: currentRound()) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || !canRedraft)
            .accessibilityIdentifier("redraftWithAnswers")
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { index < answers.count ? answers[index] : "" },
            set: { if index < answers.count { answers[index] = $0 } }
        )
    }

    /// Snapshots the current field values as a fresh answer round, paired back to
    /// the questions they answer.
    private func currentRound() -> UserSuppliedFacts {
        let paired = zip(missing, answers).map { question, response in
            UserSuppliedFacts.Answer(question: question, response: response)
        }
        return UserSuppliedFacts(answers: paired, additional: extra)
    }
}
