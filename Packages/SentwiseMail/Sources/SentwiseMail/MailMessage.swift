import Foundation

/// A parsed email address (from an IMAP envelope).
public struct MailAddress: Codable, Equatable, Sendable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }
}

/// A message summary fetched from a mailbox. Envelope-level for now; the body is
/// added in a later slice.
public struct MailMessage: Codable, Equatable, Sendable, Identifiable {
    /// The IMAP UID — stable within a mailbox.
    public var id: UInt32
    /// The mailbox UIDVALIDITY captured with this UID, when the server provides it.
    public var uidValidity: UInt32?
    public var from: MailAddress?
    /// The address replies should be sent to, when it differs from `From`.
    public var replyTo: MailAddress?
    /// Envelope recipients. This is especially useful for Sent-mail searches,
    /// where `From` is usually the connected account and the recipient links the
    /// sent message back to the source conversation.
    public var to: [MailAddress]
    public var subject: String
    public var date: String
    /// The RFC 5322 `In-Reply-To` value, when the server provides it.
    public var inReplyTo: String?
    /// The RFC 5322 `Message-ID` (with angle brackets), when the server provides
    /// it. Used to thread replies via `In-Reply-To`/`References`.
    public var messageID: String?

    public init(
        id: UInt32,
        uidValidity: UInt32? = nil,
        from: MailAddress?,
        replyTo: MailAddress? = nil,
        to: [MailAddress] = [],
        subject: String,
        date: String,
        inReplyTo: String? = nil,
        messageID: String? = nil
    ) {
        self.id = id
        self.uidValidity = uidValidity
        self.from = from
        self.replyTo = replyTo
        self.to = to
        self.subject = subject
        self.date = date
        self.inReplyTo = inReplyTo
        self.messageID = messageID
    }
}

/// A mailbox to fetch from.
public enum Mailbox: Codable, Sendable, Equatable, Hashable {
    case inbox
    case sent
    case drafts
    /// Gmail's "All Mail" — every message regardless of folder/label. Useful as
    /// the broadest target when searching for a specific message.
    case allMail
    /// The Trash / Deleted-Messages folder. Bulk "delete" moves here (recoverable).
    case trash
    /// The Archive folder. Bulk "archive" moves here (out of the inbox).
    case archive
    /// A provider-specific mailbox path (e.g. a custom IMAP folder).
    case named(String)

    /// A stable identity/label for the mailbox, used for persisted source-mailbox
    /// tags, processed-message keys, and reply-dispatch guards. Special folders
    /// use Gmail's canonical paths as opaque, provider-independent identifiers.
    ///
    /// This is NOT necessarily the live server folder — to `SELECT`/`APPEND`
    /// against a real account, use `imapName(using:)` so non-Gmail providers
    /// (Yahoo/AT&T) resolve to their own folder names.
    public var imapName: String {
        switch self {
        case .inbox: return "INBOX"
        case .sent: return "[Gmail]/Sent Mail"
        case .drafts: return "[Gmail]/Drafts"
        case .allMail: return "[Gmail]/All Mail"
        case .trash: return "[Gmail]/Trash"
        case .archive: return "[Gmail]/All Mail"
        case .named(let name): return name
        }
    }

    /// The live IMAP folder name for this account's special-folder `naming`.
    /// `.allMail` falls back to `INBOX` when the provider has no all-mail folder.
    public func imapName(using naming: MailboxNaming) -> String {
        switch self {
        case .inbox: return "INBOX"
        case .sent: return naming.sent
        case .drafts: return naming.drafts
        case .allMail: return naming.allMail ?? "INBOX"
        case .trash: return naming.trash
        case .archive: return naming.archive
        case .named(let name): return name
        }
    }

    /// Whether a fetched row has enough envelope context to generate a reply
    /// safely. Sent and Drafts rows currently only preserve `From`/`Reply-To`,
    /// which points back at the connected account for outgoing mail.
    public var supportsReplyDrafting: Bool {
        switch self {
        case .sent, .drafts:
            return false
        case .inbox, .allMail, .trash, .archive, .named:
            return true
        }
    }
}
