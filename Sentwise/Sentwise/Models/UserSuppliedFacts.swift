import Foundation

/// Facts the user typed in answer to a `NEEDS_INFO` draft (item 85). Attached to
/// the `Draft` so they survive relaunch and the pending queue, and injected into
/// the regenerate prompt as an authoritative, clearly delimited block.
///
/// **Privacy:** this is local-only free text. It leaves the machine only inside
/// the same stateless drafting call as the mail content, and is never logged or
/// written to the activity history.
struct UserSuppliedFacts: Codable, Equatable {
    /// One typed answer, paired with the missing-info question it responds to so a
    /// second `NEEDS_INFO` round can keep prior answers even as the questions change.
    struct Answer: Codable, Equatable {
        var question: String
        var response: String
    }

    /// Answers keyed to the questions the model asked, in question order.
    var answers: [Answer]
    /// The free-text "anything else" field, for facts that no question covered.
    var additional: String

    init(answers: [Answer] = [], additional: String = "") {
        self.answers = answers
        self.additional = additional
    }

    /// Answers whose response is non-blank (blank fields carry no fact).
    var nonEmptyAnswers: [Answer] {
        answers.filter { !$0.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Whether the user supplied nothing usable — no non-blank answer and no
    /// "anything else" text. Re-draft stays disabled while this is true.
    var isEmpty: Bool {
        nonEmptyAnswers.isEmpty
            && additional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Folds a fresh card round into the accumulated facts without ever dropping a
    /// prior-round answer: answers to questions already stored are overwritten,
    /// new questions are appended, and a non-blank "anything else" replaces the
    /// stored one (a blank one leaves it untouched). This is what lets a second
    /// `NEEDS_INFO` round preserve everything the user already told the assistant.
    func merging(round: UserSuppliedFacts) -> UserSuppliedFacts {
        var merged = self
        for answer in round.answers {
            let response = answer.response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !response.isEmpty else { continue }
            if let index = merged.answers.firstIndex(where: { $0.question == answer.question }) {
                merged.answers[index].response = answer.response
            } else {
                merged.answers.append(answer)
            }
        }
        let extra = round.additional.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            merged.additional = round.additional
        }
        return merged
    }

    /// The facts rendered as reply-body seed text for the "write it yourself"
    /// escape (item 85): each answer as "Question\nAnswer", then any extra text.
    var replyBodySeed: String {
        var blocks: [String] = []
        for answer in nonEmptyAnswers {
            let question = answer.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = answer.response.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(question.isEmpty ? response : "\(question)\n\(response)")
        }
        let extra = additional.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { blocks.append(extra) }
        return blocks.joined(separator: "\n\n")
    }
}
