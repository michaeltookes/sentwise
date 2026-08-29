import Foundation

/// Pure, testable filtering for the Review Drafts search field (item 76).
///
/// The search field on the review window filters the currently-visible tab
/// (Drafts or Skipped) by sender name/address and subject as the user types;
/// clearing it restores the full list. Matching is **case-insensitive** and runs
/// against the **MIME-decoded** subject (`MIMEEncodedWord.displaySubject`, item
/// 69), never the raw encoded-word header. An empty (or whitespace-only) query
/// matches everything, so clearing the field restores the full list.
///
/// Kept free of SwiftUI so the matching and count-label logic can be unit-tested
/// directly against `Draft` and `SkippedMessage` fixtures.
enum ReviewDraftsFilter {

    /// Normalizes a query for comparison: trims surrounding whitespace and
    /// lowercases. An empty result means "match everything" (no active filter).
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The searchable fields for a pending draft: sender name, sender email, and
    /// the MIME-decoded subject (item 69). Authored follow-ups (item 51) have no
    /// inbound sender, so they match on their "Post-call follow-up" label and the
    /// user-written `replySubject` — mirroring `PendingDraftRow`.
    static func searchableText(for draft: Draft) -> [String] {
        if draft.isAuthored {
            return ["Post-call follow-up", draft.replySubject]
        }
        var fields: [String] = []
        if let from = draft.sourceFrom {
            if let name = from.name { fields.append(name) }
            fields.append(from.email)
        }
        fields.append(MIMEEncodedWord.displaySubject(draft.sourceSubject))
        return fields
    }

    /// The searchable fields for a skipped message: sender name, sender email,
    /// and the MIME-decoded subject (item 69).
    static func searchableText(for skipped: SkippedMessage) -> [String] {
        var fields: [String] = []
        if let name = skipped.message.from?.name { fields.append(name) }
        if let email = skipped.senderEmail { fields.append(email) }
        fields.append(MIMEEncodedWord.displaySubject(skipped.subject))
        return fields
    }

    /// Whether a pending draft matches the query. An empty query matches all.
    static func matches(_ draft: Draft, query: String) -> Bool {
        matches(fields: searchableText(for: draft), query: query)
    }

    /// Whether a skipped message matches the query. An empty query matches all.
    static func matches(_ skipped: SkippedMessage, query: String) -> Bool {
        matches(fields: searchableText(for: skipped), query: query)
    }

    /// The badge text for a tab label. When no filter is active this is just the
    /// total (matching today's behavior); when a filter is active it becomes
    /// "N of M" (filtered of total) so it's clear filtering is on. Returns `nil`
    /// when the total is zero, so an empty tab shows no badge either way.
    static func countLabel(filtered: Int, total: Int, isFiltering: Bool) -> String? {
        guard total > 0 else { return nil }
        return isFiltering ? "\(filtered) of \(total)" : "\(total)"
    }

    private static func matches(fields: [String], query: String) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }
        return fields.contains { $0.lowercased().contains(needle) }
    }
}
