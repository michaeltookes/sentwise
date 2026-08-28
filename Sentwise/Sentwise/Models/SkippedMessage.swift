import SentwiseMail
import Foundation

/// A message the watcher passed over instead of drafting a reply to (item 17).
///
/// This is the minimal, observable skip record the activity history (item 21)
/// will later surface. It keeps enough of the original message to explain the
/// skip (sender, subject, reason, when) and to re-draft it if the user overrides
/// the decision (the full `MailMessage` plus its source `mailbox`).
struct SkippedMessage: Codable, Identifiable, Equatable {
    /// The message that was skipped, kept so an override can re-draft it through
    /// the normal pipeline.
    let message: MailMessage
    /// The mailbox the message was found in.
    let mailbox: Mailbox
    /// The account the message belongs to (normalized email).
    let account: String
    /// Why it was skipped.
    let reason: ReplyWorthinessReason
    /// When the skip was recorded.
    let skippedAt: Date

    init(
        message: MailMessage,
        mailbox: Mailbox,
        account: String,
        reason: ReplyWorthinessReason,
        skippedAt: Date = Date()
    ) {
        self.message = message
        self.mailbox = mailbox
        self.account = account
        self.reason = reason
        self.skippedAt = skippedAt
    }

    /// A stable identity for de-duping and list rendering: account + mailbox +
    /// UID (+ UIDVALIDITY when known), so the same message polled twice does not
    /// create two entries.
    var id: String {
        let validity = message.uidValidity.map(String.init) ?? "-"
        return "\(account.lowercased())|\(mailbox.imapName.lowercased())|\(message.id)|\(validity)"
    }

    /// The sender address, for display.
    var senderEmail: String? { message.from?.email }

    /// The sender's display name if present, else the address.
    var senderDisplay: String {
        message.from?.name ?? message.from?.email ?? "Unknown sender"
    }

    /// The message subject, for display.
    var subject: String { message.subject }
}
