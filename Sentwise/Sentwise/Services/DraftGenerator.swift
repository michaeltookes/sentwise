import Foundation

/// The incoming message being replied to.
struct ReplyContext: Equatable {
    var senderName: String?
    var senderEmail: String?
    var subject: String
    var body: String
}

/// Errors specific to draft generation.
enum DraftError: Error, Equatable {
    /// The model returned no usable reply text.
    case emptyDraft
    /// No AI provider is connected, so drafting can't run.
    case llmUnavailable
    /// The selected source mailbox cannot produce a safe reply recipient.
    case unsupportedSourceMailbox
    /// The draft is flagged as needing the user's input, so it cannot be sent or
    /// saved as-is (item 13).
    case needsUserInput
    /// Regeneration could not find a current source message to draft against.
    case sourceMessageUnavailable
}

/// The result of asking the model for a reply: either a ready-to-send body, or a
/// flag that the reply needs information only the user has (item 13). Keeping
/// these as distinct cases means a "needs input" outcome can never be mistaken
/// for a sendable reply.
enum DraftOutcome: Equatable {
    case ready(String)
    case needsInfo(DraftNeedsInfo)
    case notReplyWorthy(DraftNotReplyWorthy)
}

/// Produces a reply body from an incoming message and the user's voice profile
/// by prompting an LLM.
///
/// Pure and network-free: the caller injects a `complete` closure (backed by
/// `LLMProviding` in the app, a stub in tests), so prompt construction and
/// output cleaning are unit-testable. Mirrors `VoiceProfiler`.
struct DraftGenerator {
    typealias Complete = (LLMRequest) async throws -> LLMResponse

    /// Character cap on the sender's fresh message text (bounds token cost).
    var maxIncomingChars = 4000
    /// Character cap on the quoted thread history included for context.
    var maxThreadChars = 3000

    /// The sentinel the model emits (as the first line) when it can't draft a
    /// confident reply without information only the user has.
    static let needsInfoSentinel = "NEEDS_INFO:"
    /// The sentinel the model emits (as the first line) when the latest message
    /// does not call for a written reply.
    static let notReplyWorthySentinel = "NOT_REPLY_WORTHY:"

    func makeDraft(
        replyingTo context: ReplyContext,
        voiceProfile: VoiceProfile?,
        model: String,
        userSuppliedFacts: UserSuppliedFacts? = nil,
        complete: Complete
    ) async throws -> DraftOutcome {
        let request = LLMRequest(
            system: Self.systemPrompt(voiceProfile: voiceProfile),
            messages: [LLMMessage(
                role: .user,
                content: Self.userPrompt(
                    context,
                    maxChars: maxIncomingChars,
                    maxThreadChars: maxThreadChars,
                    userSuppliedFacts: userSuppliedFacts
                )
            )],
            model: model,
            maxTokens: 1024,
            temperature: 0.7
        )
        let response = try await complete(request)
        return try Self.parseOutcome(response.text)
    }

    // MARK: - Outcome parsing

    /// Classifies the model's raw output as a ready reply or a "needs input"
    /// flag. The flag is only honored when the sentinel is the first non-empty
    /// line after tolerated cleanup, so a normal reply that merely mentions
    /// "needs info" is not misclassified.
    static func parseOutcome(_ text: String) throws -> DraftOutcome {
        let body = cleaned(text)
        let lines = body.components(separatedBy: "\n")
        let firstMeaningful = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let firstTrimmed = firstMeaningful?.trimmingCharacters(in: .whitespaces) ?? ""

        let uppercasedFirstLine = firstTrimmed.uppercased()
        if uppercasedFirstLine.hasPrefix(needsInfoSentinel) {
            return .needsInfo(parseNeedsInfo(lines: lines, sentinelLine: firstTrimmed))
        }
        if uppercasedFirstLine.hasPrefix(notReplyWorthySentinel) {
            return .notReplyWorthy(parseNotReplyWorthy(sentinelLine: firstTrimmed))
        }

        guard !body.isEmpty else { throw DraftError.emptyDraft }
        return .ready(body)
    }

    /// Extracts the one-line reason (after the sentinel) and any "- " bulleted
    /// missing items that follow it.
    private static func parseNeedsInfo(lines: [String], sentinelLine: String) -> DraftNeedsInfo {
        let summary = String(sentinelLine.dropFirst(needsInfoSentinel.count))
            .trimmingCharacters(in: .whitespaces)
        let missing = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let cleanedSummary = summary.isEmpty
            ? "This reply needs information only you have."
            : summary
        return DraftNeedsInfo(summary: cleanedSummary, missing: missing)
    }

    /// Extracts the reason after the not-reply-worthy sentinel.
    private static func parseNotReplyWorthy(sentinelLine: String) -> DraftNotReplyWorthy {
        let summary = String(sentinelLine.dropFirst(notReplyWorthySentinel.count))
            .trimmingCharacters(in: .whitespaces)
        let cleanedSummary = summary.isEmpty
            ? "This message does not call for a written reply."
            : summary
        return DraftNotReplyWorthy(summary: cleanedSummary)
    }

    // MARK: - Prompt

    static func systemPrompt(voiceProfile: VoiceProfile?) -> String {
        let base = """
        You are the user's personal email assistant. Write a reply to the email \
        the user received, as if the user wrote it themselves. Output ONLY the \
        reply body — no subject line, no "Subject:" prefix, no quoted original \
        text, and no meta commentary like "Here's a draft". Match the intent of \
        the incoming email and keep the reply appropriate in length and tone. \
        You may be given earlier messages in the thread as context — use them to \
        inform your reply, but reply only to the latest message and do not quote \
        the earlier messages back.
        """
        let confidence = """
        If you cannot write a confident, complete reply because it would require \
        specific information only the user has — a fact, date, decision, number, \
        price, or attachment that is not present anywhere in this thread — do NOT \
        guess or fabricate it. Instead, respond with exactly this format and \
        nothing else:
        \(needsInfoSentinel) <one short sentence on why you can't draft it yet>
        - <a specific piece of information you need from the user>
        - <another, if applicable>
        Only use this when the reply genuinely depends on missing information; a \
        reply that just needs a normal judgment call should still be written.

        If the latest message is an automated notification, receipt, alert, \
        system update, or any other message that does not call for a written \
        reply, do NOT use the needs-info format. Instead, respond with exactly \
        this format and nothing else:
        \(notReplyWorthySentinel) <one short sentence on why no reply is useful>
        """
        let voice = voiceProfile?.promptBlock()
            ?? "Write in a natural, concise, and professional tone."
        return base + "\n\n" + confidence + "\n\n" + voice
    }

    private static func userPrompt(
        _ context: ReplyContext,
        maxChars: Int,
        maxThreadChars: Int,
        userSuppliedFacts: UserSuppliedFacts?
    ) -> String {
        let sender = senderLine(context)
        let thread = EmailThreadParser.split(context.body)
        let latest = String(thread.latest.prefix(maxChars))
        var prompt = """
        Reply to the latest message in this email thread:

        From: \(sender)
        Subject: \(context.subject)

        \(latest)
        """
        let history = EmailThreadParser.readableHistory(fromQuoted: thread.quotedHistory, maxChars: maxThreadChars)
        if !history.isEmpty {
            prompt += """


            --- Earlier in this thread (context only — do not quote it back) ---
            \(history)
            """
        }
        if let facts = userSuppliedFacts, let block = UserFactsPrompt.block(facts) {
            prompt += "\n\n" + block
        }
        return prompt
    }

    private static func senderLine(_ context: ReplyContext) -> String {
        switch (context.senderName, context.senderEmail) {
        case let (name?, email?) where !name.isEmpty:
            return "\(name) <\(email)>"
        case let (_, email?):
            return email
        case let (name?, nil) where !name.isEmpty:
            return name
        default:
            return "(unknown sender)"
        }
    }

    // MARK: - Output cleaning

    /// Trims the reply and strips a stray leading `Subject:` line the model may
    /// add despite instructions.
    static func cleaned(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("subject:")
              || first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
