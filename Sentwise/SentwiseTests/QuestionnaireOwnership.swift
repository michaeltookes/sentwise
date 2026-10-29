import Foundation

/// Decides whether a drafted follow-up has the user (not the other party) sending
/// the security questionnaire. The model's wording varies, so this is a pure,
/// separately tested predicate used by the live T1 test.
///
/// Accepted first-person forms: "I'll / I will / I'm going to / we'll" followed by
/// send, get, email, return, complete, fill out, have ... back, deliver, share,
/// forward or provide, in a clause that mentions the questionnaire; or
/// "the questionnaire ... from me". Rejected: second-person ownership
/// ("you'll send ... questionnaire", "you send", "your questionnaire back") and Dana
/// as the sender ("Dana will send", "Dana sends"). Clauses are judged separately, so
/// "You'll send me the questionnaire, and I'll send you the order form" fails.
enum QuestionnaireOwnership {
    private static let verbs = "send|get|email|return|complete|fill out|fill in|have|deliver|share|forward|provide"
    private static let firstPerson =
        #"\b(i|we)('ll| will|'m going to| am going to)\b[^,;]*\b("# + verbs + #")\b"#
    private static let fromMe = #"questionnaire[^,;]*\bfrom me\b"#
    private static let secondPerson =
        #"\byou('ll| will|'re going to| are going to)?\s+("# + verbs + #")\b[^,;]*questionnaire"#
    private static let danaSends =
        #"\bdana('s)?\s+(will\s+|to\s+|is going to\s+)?(send|sends|email|share|forward|return|complete|provide)\b[^,;]*questionnaire"#

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func clauses(in body: String) -> [String] {
        body.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n;"))
            .flatMap { $0.components(separatedBy: ", and ") }
            .flatMap { $0.components(separatedBy: " but ") }
            .filter { $0.contains("questionnaire") }
    }

    static func isUserOwned(_ body: String) -> Bool {
        let relevant = clauses(in: body)
        guard !relevant.isEmpty else { return false }
        let rejected = relevant.contains {
            matches(secondPerson, $0) || matches(danaSends, $0) || $0.contains("your questionnaire back")
        }
        return !rejected && relevant.contains { matches(firstPerson, $0) || matches(fromMe, $0) }
    }
}
