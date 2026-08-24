import Foundation

/// Applies the configured signature policy (item 24) to a generated draft body
/// at assembly time — the core fix for drafts that either dropped the user's
/// signature or duplicated one the model already wrote.
///
/// Pure and unit-tested. Two rules make it safe to run on every draft:
///  * **Never duplicate.** If the body already ends with the configured
///    signature, or with any recognizable signature block the model emitted on
///    its own, nothing is appended.
///  * **Correct placement.** When the body carries quoted history, the signature
///    goes after the freshly-written reply and above the quoted thread, matching
///    normal email convention. (Sentwise's own reply drafts carry no quoted
///    history, but the model can include some, and follow-ups never do.)
enum SignatureApplier {

    /// Returns `body` with the signature applied per `policy`.
    ///
    /// For `.none`, the body is returned untouched — a model-written closing is
    /// left as-is rather than stripped. For `.custom`, the trimmed signature is
    /// appended only when the body needs it (see `needsSignature`). Empty or
    /// flagged bodies (e.g. a "needs info" outcome carries an empty body) are
    /// returned unchanged so no signature is bolted onto a non-reply.
    static func apply(policy: SignaturePolicy, signature: String, to body: String) -> String {
        guard policy == .custom else { return body }
        let sig = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sig.isEmpty else { return body }

        let thread = EmailThreadParser.splitAtTrailingHistory(body)
        let newBody = thread.latest
        guard !newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return body }
        guard needsSignature(newBody, signature: sig) else { return body }

        let signedNewBody = trimmingTrailingBlankSpace(newBody) + "\n\n" + sig
        let history = thread.quotedHistory
        return history.isEmpty ? signedNewBody : signedNewBody + "\n\n" + history
    }

    /// Whether the fresh reply text still needs the signature appended: it does
    /// unless it already ends with the configured signature or with some other
    /// recognizable signature block the model produced.
    static func needsSignature(_ newBody: String, signature: String) -> Bool {
        !endsWithConfiguredSignature(newBody, signature: signature)
            && !endsWithModelWrittenSignature(newBody)
    }

    /// Whether `newBody`'s trailing non-blank lines exactly match the configured
    /// signature (compared case-insensitively, blank lines ignored). Catches a
    /// signature with no sign-off cue or `--` delimiter, which the block
    /// detector alone would miss.
    static func endsWithConfiguredSignature(_ newBody: String, signature: String) -> Bool {
        let sigLines = comparableLines(signature)
        guard !sigLines.isEmpty else { return false }
        let bodyLines = comparableLines(newBody)
        guard bodyLines.count >= sigLines.count else { return false }
        return Array(bodyLines.suffix(sigLines.count)) == sigLines
    }

    // MARK: - Helpers

    /// Non-blank lines, trimmed and lowercased, for tolerant suffix comparison.
    private static func comparableLines(_ text: String) -> [String] {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func endsWithModelWrittenSignature(_ newBody: String) -> Bool {
        guard let candidate = SignatureDetector.signatureCandidate(newBody) else { return false }
        switch candidate.anchor {
        case .delimiter:
            return true
        case .signOff:
            return signOffCandidateHasDetail(candidate.display)
        }
    }

    private static func signOffCandidateHasDetail(_ candidate: String) -> Bool {
        let lines = candidate
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, SignatureDetector.isSignOff(first) else { return true }
        return lines.dropFirst().contains { !$0.isEmpty }
    }

    /// Drops trailing whitespace and blank lines so the appended gap is exactly
    /// one blank line.
    private static func trimmingTrailingBlankSpace(_ text: String) -> String {
        var slice = Substring(text)
        while let last = slice.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
            slice = slice.dropLast()
        }
        return String(slice)
    }
}
