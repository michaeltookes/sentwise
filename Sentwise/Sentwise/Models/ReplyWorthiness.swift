import SentwiseMail
import Foundation

/// Why a message was skipped instead of drafted (item 17). Recorded on the skip
/// log so the user can see what the watcher passed over — and later surfaced by
/// the activity history (item 21).
enum ReplyWorthinessReason: String, Equatable, Codable, CaseIterable {
    /// The sender is a no-reply / automated address (`no-reply@`, `notifications@`,
    /// `mailer-daemon@`, …) — a human reply would go nowhere useful.
    case noReplySender
    /// Mailing-list or bulk mail (`List-Id`, `List-Unsubscribe`, `Precedence:
    /// bulk|list|junk`) — newsletters and blasts, not personal correspondence.
    case bulkOrListMail
    /// Machine-generated notification (`Auto-Submitted` other than `no`, or an
    /// auto-reply suppress directive) — receipts, alerts, and system mail.
    case automatedNotification
    /// A calendar invite (`Content-Type: text/calendar`) — handled by the
    /// calendar client, not a written reply.
    case calendarInvite
    /// The sender matches an entry on the user's blocklist (item 18) — the user
    /// asked the watcher never to draft replies to this sender or domain.
    case senderBlocklisted
    /// The drafting model itself judged there was nothing to reply to — it
    /// returned a needs-info / automated verdict with no sendable body (item 67).
    /// This is the LLM relevance *backstop*: the item 17/66 heuristics run first,
    /// and this only catches automated/reply-less mail that slips past them.
    case notReplyWorthyPerModel

    /// A short headline for skip-log / activity UI.
    var headline: String {
        switch self {
        case .noReplySender: return "No-reply sender"
        case .bulkOrListMail: return "Bulk or list mail"
        case .automatedNotification: return "Automated notification"
        case .calendarInvite: return "Calendar invite"
        case .senderBlocklisted: return "Blocked sender"
        case .notReplyWorthyPerModel: return "Nothing to reply to"
        }
    }

    /// A one-line explanation of why the message was passed over.
    var detail: String {
        switch self {
        case .noReplySender:
            return "This came from a no-reply or automated address, so a written reply wouldn't reach a person."
        case .bulkOrListMail:
            return "This looks like a mailing-list or bulk message rather than personal correspondence."
        case .automatedNotification:
            return "This is a machine-generated notification, so there's likely nothing to reply to."
        case .calendarInvite:
            return "This is a calendar invite — it's handled in your calendar, not with a written reply."
        case .senderBlocklisted:
            return "You added this sender to your blocklist, so the watcher skipped it."
        case .notReplyWorthyPerModel:
            return "The assistant read this and couldn't compose a reply worth sending — it looks "
                + "automated or doesn't call for one. Use \"Draft anyway\" if you'd like to reply."
        }
    }
}

/// The result of judging whether a message is worth drafting a reply to.
enum ReplyWorthinessVerdict: Equatable {
    /// Worth a draft — the watcher should proceed to the LLM.
    case worthy
    /// Not worth a draft; carries why so the skip log can explain it.
    case skip(ReplyWorthinessReason)

    var skipReason: ReplyWorthinessReason? {
        if case .skip(let reason) = self { return reason }
        return nil
    }

    var isWorthy: Bool { skipReason == nil }
}

/// The inputs the reply-worthiness check reasons over: the candidate sender
/// addresses plus the bounded header fields (`MailHeaderFields`). Kept as a plain
/// value so the evaluator stays pure and exhaustively unit-testable with no IO.
///
/// `senderEmails` carries **both** the `From` and `Reply-To` addresses (item 66):
/// a no-reply/automated pattern on *either* skips the message. Evaluating only
/// the reply target missed GitHub, whose mail is `From: notifications@github.com`
/// — a token the list already catches — but whose `Reply-To` is a routable
/// `reply+…@reply.github.com` that hides the automated `From`.
struct ReplyWorthinessSignals: Equatable {
    /// The addresses to judge (typically `From` and `Reply-To`); `nil` entries
    /// and duplicates are harmless — matching is any-of.
    var senderEmails: [String?]
    var headers: MailHeaderFields

    /// Single-address convenience kept for the many reply-target-only call sites
    /// and tests; wraps the one address into `senderEmails`.
    init(senderEmail: String?, headers: MailHeaderFields = MailHeaderFields()) {
        self.senderEmails = [senderEmail]
        self.headers = headers
    }

    /// Multi-address form (item 66): pass both `From` and `Reply-To`.
    init(senderEmails: [String?], headers: MailHeaderFields = MailHeaderFields()) {
        self.senderEmails = senderEmails
        self.headers = headers
    }
}

/// Pure, synchronous reply-worthiness evaluation, isolated from IMAP so the
/// heuristics can be exhaustively unit-tested (item 17). Mirrors the
/// `StaleThreadCheck` pattern (item 12): typed inputs in, a typed verdict out,
/// no side effects.
///
/// The heuristics are deliberately **conservative**: when in doubt, return
/// `.worthy`. A false skip silently loses a real reply; a false "worthy" only
/// costs one throwaway draft the user can ignore.
enum ReplyWorthiness {

    /// Judges whether `signals` describe a message worth drafting a reply to.
    /// Checks run high-precision first; the first match wins and names the reason.
    static func evaluate(_ signals: ReplyWorthinessSignals) -> ReplyWorthinessVerdict {
        if signals.senderEmails.contains(where: isNoReplySender) {
            return .skip(.noReplySender)
        }
        if isCalendarInvite(signals.headers) {
            return .skip(.calendarInvite)
        }
        if isBulkOrListMail(signals.headers) {
            return .skip(.bulkOrListMail)
        }
        if isAutomatedNotification(signals.headers) {
            return .skip(.automatedNotification)
        }
        // Sender-based transactional check runs last, so it only catches mail the
        // header/no-reply checks left as `.worthy` (item 66). Reported as an
        // automated notification — a receipt/order/alert is machine-issued even
        // when its `Reply-To` points at a staffed inbox like `support@`.
        if signals.senderEmails.contains(where: isTransactionalSender) {
            return .skip(.automatedNotification)
        }
        return .worthy
    }

    // MARK: - No-reply senders

    /// Local-part tokens that mark an address as no-reply / automated when the
    /// local part equals one of them.
    private static let noReplyExactLocalParts: Set<String> = [
        "no-reply", "noreply", "no_reply",
        "donotreply", "do-not-reply", "do_not_reply", "donot-reply",
        "notifications", "notification", "notify",
        "mailer-daemon", "mailerdaemon",
        "postmaster",
        "bounce", "bounces"
    ]

    /// Substrings that mark an address as no-reply / automated when contained in
    /// the local part (catches `no-reply-123`, `bounces+tag`, `github-noreply`).
    private static let noReplyContainedTokens: [String] = [
        "no-reply", "noreply", "no_reply",
        "donotreply", "do-not-reply", "do_not_reply",
        "mailer-daemon",
        "bounce"
    ]

    /// Whether the address looks like a no-reply / automated sender. Reasons over
    /// the local part (before `@`) so the domain never triggers a false skip.
    static func isNoReplySender(_ email: String?) -> Bool {
        guard let localPart = normalizedLocalPart(email) else { return false }
        if noReplyExactLocalParts.contains(localPart) { return true }
        return noReplyContainedTokens.contains { localPart.contains($0) }
    }

    private static func normalizedLocalPart(_ email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !email.isEmpty else {
            return nil
        }
        let localPart = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? email
        return localPart.isEmpty ? nil : localPart
    }

    // MARK: - Transactional senders (item 66)

    /// Local parts (matched **exactly**, after stripping any RFC 5233 `+tag`
    /// subaddress) that mark machine-issued transactional mail when paired with a
    /// known transactional domain. These catch receipts and order updates that
    /// carry no `List-Unsubscribe` / `Auto-Submitted` header and no no-reply token,
    /// so they slipped past the item 17 heuristics into Review Drafts.
    ///
    /// **Exact-match, not contained, on purpose.** A contained `invoice` would
    /// also skip a human `invoice-questions@`, and — the case the item 66 note
    /// calls out — a bare contained `billing`/`support` would kill a genuine
    /// `billing@`/`support@` back-and-forth. So `support` and `billing` are
    /// deliberately **absent**, and the compound retailer tokens (`order-update`,
    /// `auto-confirm`, `shipment-tracking`) are listed in full rather than as the
    /// broad substrings `order`/`confirm`/`tracking`. Stripping the `+tag` first
    /// is what lets Stripe/Anthropic's `invoice+statements@` match the base
    /// `invoice`. These tokens are not enough on their own: a human-managed
    /// `invoice@accounting-firm.example` must remain worthy.
    private static let transactionalExactLocalParts: Set<String> = [
        // Receipts / invoices / statements (Stripe, Anthropic, generic billing).
        "invoice", "invoices",
        "receipt", "receipts",
        "statement", "statements",
        // Order / shipment lifecycle mail from retailers (Amazon and peers).
        "orders", "order-update", "order-updates",
        "auto-confirm", "autoconfirm",
        "shipment", "shipments", "shipment-tracking",
        // Budget / cost / system alerts (AWS Budgets local part is `budgets`).
        "budget", "budgets",
        "alert", "alerts"
    ]

    /// Domains where an exact transactional local part is enough corroboration to
    /// treat the sender as automated. Matched on an exact-domain or dot-boundary
    /// subdomain basis (never substring), mirroring the item 18 `SenderRules`
    /// discipline so a look-alike domain can't false-match.
    private static let transactionalLocalPartDomains: Set<String> = [
        "stripe.com",
        "anthropic.com",
        "amazon.com"
    ]

    /// Sending domains that are automated/transactional by nature — the signal
    /// when the local part carries no token (item 66).
    private static let automatedSenderDomains: Set<String> = [
        // AWS Budgets / Cost Explorer alerts — no human mailbox lives here.
        "costalerts.amazonaws.com",
        // JazzHR applicant-tracking recruiting blasts. A candidate reply is
        // routed by the ATS rather than read as personal mail, so item 66 treats
        // these as not reply-worthy; documented here as the one borderline call.
        "applytojob.com"
    ]

    /// Whether the domain itself, or a transactional local part corroborated by a
    /// known transactional domain, marks the address as automated (item 66).
    static func isTransactionalSender(_ email: String?) -> Bool {
        guard let domain = normalizedDomain(email) else { return false }
        if matchesAutomatedDomain(domain) {
            return true
        }
        guard matchesTransactionalLocalPartDomain(domain),
              let base = baseLocalPart(email),
              transactionalExactLocalParts.contains(base) else { return false }
        return true
    }

    /// The local part with any RFC 5233 `+tag` subaddress removed, lowercased, so
    /// `invoice+statements` and `order-update+abc` match their base token.
    private static func baseLocalPart(_ email: String?) -> String? {
        guard let localPart = normalizedLocalPart(email) else { return nil }
        let base = localPart.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? localPart
        return base.isEmpty ? nil : base
    }

    private static func normalizedDomain(_ email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !email.isEmpty else {
            return nil
        }
        let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let domain = String(parts[1])
        return domain.isEmpty ? nil : domain
    }

    private static func matchesAutomatedDomain(_ domain: String) -> Bool {
        matchesDomain(domain, in: automatedSenderDomains)
    }

    private static func matchesTransactionalLocalPartDomain(_ domain: String) -> Bool {
        matchesDomain(domain, in: transactionalLocalPartDomains)
    }

    private static func matchesDomain(_ domain: String, in candidates: Set<String>) -> Bool {
        candidates.contains { candidate in
            domain == candidate || domain.hasSuffix("." + candidate)
        }
    }

    // MARK: - Bulk / list mail

    /// Precedence values that mark non-personal mail.
    private static let bulkPrecedenceValues: Set<String> = ["bulk", "list", "junk"]

    static func isBulkOrListMail(_ headers: MailHeaderFields) -> Bool {
        if isPresent(headers.listID) { return true }
        if isPresent(headers.listUnsubscribe) { return true }
        if let precedence = normalizedValue(headers.precedence),
           bulkPrecedenceValues.contains(precedence) {
            return true
        }
        return false
    }

    // MARK: - Automated notifications

    /// `X-Auto-Response-Suppress` is a recipient-side suppression directive, not
    /// a reliable automation declaration. Treat only broad auto-reply suppression
    /// as an automation signal; receipt-only values (DR/RN/NRN) remain worthy.
    private static let autoResponseSuppressAutomationValues: Set<String> = [
        "all", "autoreply", "auto-reply", "oof"
    ]

    static func isAutomatedNotification(_ headers: MailHeaderFields) -> Bool {
        if hasSuppressingAutoResponseValue(headers.autoResponseSuppress) { return true }
        if let autoSubmitted = normalizedValue(headers.autoSubmitted) {
            // RFC 3834: `no` means "not automated"; any other value (auto-
            // generated, auto-replied, …) marks machine-submitted mail.
            let value = autoSubmitted.split(separator: ";", maxSplits: 1).first.map(String.init) ?? autoSubmitted
            return value.trimmingCharacters(in: .whitespaces) != "no"
        }
        return false
    }

    private static func hasSuppressingAutoResponseValue(_ value: String?) -> Bool {
        guard let value = normalizedValue(value) else { return false }
        let tokens = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        return tokens.contains { autoResponseSuppressAutomationValues.contains($0) }
    }

    // MARK: - Calendar invites

    static func isCalendarInvite(_ headers: MailHeaderFields) -> Bool {
        let contentTypes = [headers.contentType].compactMap { normalizedValue($0) }
            + headers.bodyContentTypes.compactMap { normalizedValue($0) }
        return contentTypes.contains(where: isCalendarInviteContentType)
    }

    private static func isCalendarInviteContentType(_ contentType: String) -> Bool {
        let mediaType = contentType.split(separator: ";", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? contentType
        guard mediaType == "text/calendar" || mediaType == "application/ics" else { return false }
        return parameterValue(named: "method", in: contentType) == "request"
    }

    private static func parameterValue(named name: String, in contentType: String) -> String? {
        for component in contentType.split(separator: ";").dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }
            return pair[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    // MARK: - Helpers

    private static func isPresent(_ value: String?) -> Bool {
        (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    private static func normalizedValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
