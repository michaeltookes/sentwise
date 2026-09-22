import Foundation

/// What the sender allow/blocklist has to say about a message (item 18).
enum SenderRuleDecision: Equatable {
    /// An allowlist rule wins: draft this message regardless of the
    /// reply-worthiness heuristics (item 17).
    case forceDraft
    /// A blocklist rule wins: skip this message with a visible reason.
    case block
    /// No rule applies: fall through to the reply-worthiness heuristics.
    case noOpinion
}

/// Pure, IO-free evaluation of the sender allow/blocklist (item 18), mirroring
/// the `ReplyWorthiness` (item 17) pattern: typed inputs in, a typed decision
/// out, no side effects, exhaustively unit-testable.
///
/// ## Precedence (chosen and load-bearing)
/// **Most specific match wins.** A full-address rule (specificity 2) out-ranks a
/// domain rule (specificity 1). When the strongest allow match and the strongest
/// block match tie in specificity, the **blocklist wins** (deny-overrides /
/// fail-safe): honoring the user's explicit exclusion, and preferring to skip a
/// draft over drafting against something the user asked to block.
///
/// Choosing specificity over a blanket "block always wins" is deliberate: it lets
/// a user block an entire domain yet still allowlist one specific address inside
/// it (the address rule out-specifies the domain block), which is the main real
/// reason to want both lists at once. A blanket block-wins rule would make that
/// allow entry impossible to honor.
enum SenderRules {

    /// Address matches are more specific than domain matches.
    private static let addressSpecificity = 2
    private static let domainSpecificity = 1

    /// Decides what the rules say about `senderEmail`. The sender is the message's
    /// `From` address — the person the user sees as having sent the mail — matched
    /// case-insensitively.
    static func decide(
        senderEmail: String?,
        allowlist: [SenderRule],
        blocklist: [SenderRule]
    ) -> SenderRuleDecision {
        guard let sender = SenderIdentity(senderEmail) else { return .noOpinion }
        let allow = bestSpecificity(matching: sender, in: allowlist)
        let block = bestSpecificity(matching: sender, in: blocklist)
        switch (allow, block) {
        case (nil, nil):
            return .noOpinion
        case (.some, nil):
            return .forceDraft
        case (nil, .some):
            return .block
        case let (.some(allowScore), .some(blockScore)):
            // Most specific wins; on a tie, block wins (deny-overrides).
            return blockScore >= allowScore ? .block : .forceDraft
        }
    }

    /// Whether `senderEmail` matches any rule in `list` (item 108 auto-draft
    /// list). Reuses the same address/domain specificity and subdomain-boundary
    /// matching as the allow/blocklist, so `example.com` also matches
    /// `mail.example.com` and never false-matches a look-alike domain.
    static func matches(senderEmail: String?, in list: [SenderRule]) -> Bool {
        guard let sender = SenderIdentity(senderEmail) else { return false }
        return bestSpecificity(matching: sender, in: list) != nil
    }

    /// The specificity of the strongest rule in `rules` that matches `sender`, or
    /// `nil` when none matches.
    private static func bestSpecificity(matching sender: SenderIdentity, in rules: [SenderRule]) -> Int? {
        rules.compactMap { specificity(of: $0, matching: sender) }.max()
    }

    /// The specificity with which `rule` matches `sender`, or `nil` for no match.
    private static func specificity(of rule: SenderRule, matching sender: SenderIdentity) -> Int? {
        switch rule.kind {
        case .address:
            return rule.pattern == sender.address ? addressSpecificity : nil
        case .domain:
            guard let domain = sender.domain else { return nil }
            // Exact domain, or a subdomain on a dot boundary (`example.com` also
            // covers `mail.example.com`). Never a substring match, so a domain
            // rule can't false-match a local part or a look-alike domain.
            if domain == rule.pattern || domain.hasSuffix("." + rule.pattern) {
                return domainSpecificity
            }
            return nil
        }
    }
}

/// The normalized sender identity the rules reason over: the full address plus its
/// domain part, if any. Kept as a plain value so `SenderRules` stays pure.
struct SenderIdentity: Equatable {
    /// The full address, trimmed and lowercased.
    let address: String
    /// The part after the last `@`, lowercased, or `nil` if the address has none.
    let domain: String?

    init?(_ email: String?) {
        guard let value = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        self.address = value
        if let atIndex = value.lastIndex(of: "@") {
            let domainPart = value[value.index(after: atIndex)...]
            self.domain = domainPart.isEmpty ? nil : String(domainPart)
        } else {
            self.domain = nil
        }
    }
}
