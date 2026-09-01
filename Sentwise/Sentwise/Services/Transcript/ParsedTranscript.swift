import Foundation

/// A transcript normalized to speaker-preserving plain text, ready to feed the
/// follow-up drafting prompt (item 51).
struct ParsedTranscript: Codable, Equatable {
    /// The conversation as plain text: one speaker turn per line where labels
    /// exist (`Name: said this`), timestamps and cue numbers stripped.
    var text: String
    /// Whether the source carried explicit speaker labels (`Name:` prefixes or
    /// WebVTT `<v Name>` voice tags). The prompt adapts to labeled vs unlabeled
    /// transcripts, so this is surfaced to the generator.
    var hasSpeakerLabels: Bool

    /// Whether there is any usable conversation text after parsing.
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Bounded source context persisted with authored follow-ups so a later
/// `NEEDS_INFO` re-draft can reuse the complete call context without storing an
/// unbounded transcript in the pending queue.
struct FollowUpDraftContext: Codable, Equatable {
    enum Source: String, Codable {
        case transcript
        case summary
    }

    var text: String
    var hasSpeakerLabels: Bool
    var source: Source

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func transcript(_ transcript: ParsedTranscript) -> FollowUpDraftContext {
        FollowUpDraftContext(
            text: transcript.text,
            hasSpeakerLabels: transcript.hasSpeakerLabels,
            source: .transcript
        )
    }

    static func summary(_ text: String, hasSpeakerLabels: Bool) -> FollowUpDraftContext {
        FollowUpDraftContext(
            text: text,
            hasSpeakerLabels: hasSpeakerLabels,
            source: .summary
        )
    }
}
