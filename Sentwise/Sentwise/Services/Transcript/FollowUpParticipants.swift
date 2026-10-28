import Foundation
import SentwiseMail

/// Who is who in a post-call follow-up (item 138): the user is the "I" of the
/// draft and the recipient is the call participant being written to. Stating
/// both in the prompt keeps the model from greeting the user, or handing the
/// user's own commitments to the other side.
struct FollowUpParticipants: Equatable {
    /// The signed-in mailbox address (the sender).
    var userEmail: String?
    /// Name hints for the user beyond the mailbox, e.g. the name in the sign-off.
    var userNameHints: [String] = []
    /// The chosen recipients, when known. Display names are used; addresses are not
    /// mined for names (a mailbox address may be the user's own).
    var recipients: [MailAddress] = []

    init(userEmail: String? = nil, userNameHints: [String] = [], recipients: [MailAddress] = []) {
        self.userEmail = userEmail
        self.userNameHints = userNameHints
        self.recipients = recipients
    }

    /// Builds participants from the account, its voice profile and the recipients.
    init(userEmail: String?, voiceProfile: VoiceProfile?, recipients: [MailAddress]) {
        self.init(
            userEmail: userEmail,
            userNameHints: Self.signOffNameHints(from: voiceProfile?.signOff),
            recipients: recipients
        )
    }

    // MARK: - Resolution

    /// The transcript speaker labels in order of first appearance, without any
    /// parenthetical affiliation ("Dana (Acme)" becomes "Dana").
    static func speakerLabels(in text: String) -> [String] {
        var labels: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let label = speakerLabel(of: String(line)) else { continue }
            if !labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
                labels.append(label)
            }
        }
        return labels
    }

    private static func speakerLabel(of line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var head = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        if let paren = head.firstIndex(of: "(") {
            head = String(head[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        guard !head.isEmpty, head.count <= 40, head.split(separator: " ").count <= 4,
              head.first?.isLetter == true,
              head.allSatisfy({ $0.isLetter || " '’.-".contains($0) }) else { return nil }
        return head
    }

    /// The speaker label that is the user. Exact identity matches (a name hint or
    /// the mailbox local part equal to the label's first name or full label) are
    /// evaluated first; the mailbox-prefix heuristic is used only when no exact
    /// match exists. If more than one label ties at the deciding level the result
    /// is `nil`: no ownership is asserted (unlabeled-transcript behaviour).
    func userSpeaker(in labels: [String]) -> String? {
        let local = userEmail?.split(separator: "@").first.map { $0.lowercased() } ?? ""
        let hintNames = userNameHints.map { $0.lowercased() }
        let hintTokens = Set(hintNames.flatMap { $0.split(separator: " ").map(String.init) })
        let exact = labels.filter { label in
            let full = label.lowercased()
            let first = Self.firstName(of: label).lowercased()
            return hintNames.contains(full) || (first.count >= 3 && hintTokens.contains(first))
                || (!local.isEmpty && (full == local || first == local))
        }
        if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        guard !local.isEmpty else { return nil }
        let prefixed = labels.filter { label in
            let first = Self.firstName(of: label).lowercased()
            return first.count >= 3 && (local.hasPrefix(first) || first.hasPrefix(local))
        }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// The first name to greet: the chosen recipient's display name, else the
    /// single non-user speaker in a labeled transcript, else `nil`.
    func recipientFirstName(transcript text: String, hasSpeakerLabels: Bool) -> String? {
        for recipient in recipients {
            if let name = recipient.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return Self.firstName(of: name)
            }
        }
        guard hasSpeakerLabels else { return nil }
        let labels = Self.speakerLabels(in: text)
        let user = userSpeaker(in: labels)
        let others = labels.filter { $0 != user }
        let firstNames = Set(others.map { Self.firstName(of: $0).lowercased() })
        guard firstNames.count == 1, let only = others.first else { return nil }
        return Self.firstName(of: only)
    }

    // MARK: - Prompt

    /// The "who is who" block for the follow-up system prompt.
    func promptBlock(transcript text: String, hasSpeakerLabels: Bool) -> String {
        var lines = ["Who is who:"]
        var userLine = "- The user is the sender: every \"I\", \"me\" and \"my\" in the email is the user"
        if let email = userEmail, !email.isEmpty { userLine += " (mailbox \(email))" }
        userLine += "."
        lines.append(userLine)
        let labels = hasSpeakerLabels ? Self.speakerLabels(in: text) : []
        if let user = userSpeaker(in: labels) {
            lines.append("- In the transcript the user is the speaker labeled \"\(user)\". Whatever \(user) "
                + "says they will do is the user's own action item: write it as \"I will ...\". "
                + "Never assign it to anyone else.")
        } else if hasSpeakerLabels {
            lines.append("- Work out which speaker label is the user from the mailbox and sign-off above; "
                + "commitments the user makes in the call are written as \"I will ...\".")
        }
        if let name = recipientFirstName(transcript: text, hasSpeakerLabels: hasSpeakerLabels) {
            lines.append("- The email is addressed to \(name), the other person on the call. Greet \(name) "
                + "and refer to \(name) as \"you\". Never greet the user by name, and never use a "
                + "name taken from the writing-voice notes.")
        } else {
            lines.append("- The email is addressed to the other participant(s) on the call, but no name is "
                + "known for them. Open with a greeting that uses no name (for example \"Hi,\" or "
                + "\"Hello,\"). Do not invent a name, do not write a placeholder, never greet the user "
                + "by name, and never use a name taken from the writing-voice notes.")
        }
        lines.append("- Keep every quantity, duration, price and date exactly as stated in the call "
            + "(seat counts, lengths such as \"30-day\", dates such as \"November 2\"). Do not drop "
            + "or round them.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func firstName(of fullName: String) -> String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }

    /// The name on the last line of a sign-off ("Best,\nMichael" gives ["Michael"]).
    static func signOffNameHints(from signOff: String?) -> [String] {
        guard let signOff else { return [] }
        let lines = signOff.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1, let last = lines.last, last.split(separator: " ").count <= 3,
              last.first?.isLetter == true, !last.contains(",") else { return [] }
        return [last]
    }
}
