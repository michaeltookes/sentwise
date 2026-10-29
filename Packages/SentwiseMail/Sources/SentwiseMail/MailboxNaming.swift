import Foundation

/// The provider-specific names of a mailbox's special folders (Sent, Drafts,
/// All-Mail, Junk).
///
/// IMAP has no universal names for these: Gmail uses `[Gmail]/Sent Mail`,
/// Yahoo/AT&T use `Sent` / `Draft` / `Bulk Mail`, while iCloud uses
/// `Sent Messages` for sent mail. Most non-Gmail providers have no all-mail
/// folder at all. So the correct folder is resolved per account (from the IMAP
/// host) rather than hardcoded to Gmail. A future enhancement can discover these
/// from the server via IMAP `LIST` SPECIAL-USE attributes (RFC 6154).
public struct MailboxNaming: Equatable, Sendable {
    public var sent: String
    public var drafts: String
    /// The "all mail" / archive-of-everything folder, or `nil` when the provider
    /// has none (Yahoo/AT&T). Callers fall back to INBOX when this is `nil`.
    public var allMail: String?
    /// The spam/junk folder, when known.
    public var junk: String?
    /// The Trash / Deleted-Messages folder that deleted mail is moved to. Bulk
    /// "delete" moves to Trash (recoverable) rather than permanently expunging.
    public var trash: String
    /// The folder that "archive" moves mail out of the inbox into. On Gmail this
    /// is All Mail (moving there simply removes the `INBOX` label = archive).
    public var archive: String

    public init(
        sent: String,
        drafts: String,
        allMail: String?,
        junk: String? = nil,
        trash: String = "Trash",
        archive: String = "Archive"
    ) {
        self.sent = sent
        self.drafts = drafts
        self.allMail = allMail
        self.junk = junk
        self.trash = trash
        self.archive = archive
    }

    /// Gmail's special-folder layout (the historical default).
    public static let gmail = MailboxNaming(
        sent: "[Gmail]/Sent Mail",
        drafts: "[Gmail]/Drafts",
        allMail: "[Gmail]/All Mail",
        junk: "[Gmail]/Spam",
        trash: "[Gmail]/Trash",
        archive: "[Gmail]/All Mail"
    )

    /// Yahoo-family layout, which also covers AT&T (`att.net`), AOL, and other
    /// Yahoo-backed hosts. These providers have no all-mail folder.
    public static let yahoo = MailboxNaming(
        sent: "Sent",
        drafts: "Draft",
        allMail: nil,
        junk: "Bulk Mail",
        trash: "Trash",
        archive: "Archive"
    )

    /// iCloud/Me/Mac layout. iCloud uses a non-generic Sent folder name and has
    /// no all-mail folder.
    public static let icloud = MailboxNaming(
        sent: "Sent Messages",
        drafts: "Drafts",
        allMail: nil,
        junk: "Junk",
        trash: "Deleted Messages",
        archive: "Archive"
    )

    /// Microsoft (Outlook.com, Hotmail, Exchange Online) documented defaults
    /// (item 31, T31-8). These are only the last fallback: `discovering(from:)`
    /// overrides them with the server's SPECIAL-USE attributes, which also covers
    /// localized folder names.
    public static let microsoft = MailboxNaming(
        sent: "Sent Items",
        drafts: "Drafts",
        allMail: nil,
        junk: "Junk Email",
        trash: "Deleted Items",
        archive: "Archive"
    )

    /// A conservative layout for unrecognized IMAP providers.
    public static let generic = MailboxNaming(
        sent: "Sent",
        drafts: "Drafts",
        allMail: nil,
        junk: "Junk",
        trash: "Trash",
        archive: "Archive"
    )

    /// Whether this account exposes an all-mail folder (drives whether an
    /// "All Mail" search target is offered).
    public var supportsAllMail: Bool { allMail != nil }

    /// Resolves the special-folder layout for an IMAP host, falling back to the
    /// generic layout for unrecognized hosts.
    public static func forHost(_ host: String) -> MailboxNaming {
        let lowered = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("gmail") || lowered.contains("googlemail") {
            return .gmail
        }
        if yahooBackedFragments.contains(where: lowered.contains) {
            return .yahoo
        }
        if icloudHostSuffixes.contains(where: lowered.hasSuffix) {
            return .icloud
        }
        if microsoftHostSuffixes.contains(where: lowered.hasSuffix) {
            return .microsoft
        }
        return .generic
    }

    /// Host substrings that identify a Yahoo-backed provider.
    private static let yahooBackedFragments = [
        "yahoo", "att.net", "mail.att", "aol", "ymail", "rocketmail",
        "sbcglobal", "bellsouth"
    ]

    /// Host suffixes that identify a Microsoft-hosted mailbox.
    private static let microsoftHostSuffixes = [
        "outlook.office365.com", "outlook.office.com", "imap-mail.outlook.com"
    ]

    /// Host suffixes that identify an iCloud-backed provider.
    private static let icloudHostSuffixes = [
        "mail.me.com", "mail.icloud.com"
    ]
}

// MARK: - SPECIAL-USE discovery (RFC 6154, with the Gmail/Outlook XLIST dialect)

/// One mailbox from an IMAP `LIST` (or `XLIST`) response: its attributes and name.
public struct MailboxListEntry: Equatable, Sendable {
    /// Attributes as the server sent them, backslash included (`\Sent`).
    public var attributes: [String]
    public var name: String

    public init(attributes: [String], name: String) {
        self.attributes = attributes
        self.name = name
    }
}

extension MailboxNaming {

    /// Returns a copy of this layout with sent / drafts / junk / trash / archive
    /// replaced by whatever the server marked with `\Sent`, `\Drafts`, `\Junk`
    /// (or XLIST's `\Spam`), `\Trash` and `\Archive`. A role the server did not
    /// mark keeps this layout's value, so the documented defaults are the last
    /// fallback. `allMail` is never changed. Only Microsoft accounts call this at
    /// connect; shipped providers keep their static names.
    public func discovering(from entries: [MailboxListEntry]) -> MailboxNaming {
        var result = self
        func name(for attributes: [String]) -> String? {
            for entry in entries where !entry.name.isEmpty {
                let lowered = Set(entry.attributes.map { $0.lowercased() })
                if attributes.contains(where: { lowered.contains($0) }) { return entry.name }
            }
            return nil
        }
        if let sent = name(for: ["\\sent"]) { result.sent = sent }
        if let drafts = name(for: ["\\drafts"]) { result.drafts = drafts }
        if let junk = name(for: ["\\junk", "\\spam"]) { result.junk = junk }
        if let trash = name(for: ["\\trash"]) { result.trash = trash }
        if let archive = name(for: ["\\archive"]) { result.archive = archive }
        return result
    }

    /// Parses raw untagged `LIST` / `XLIST` response lines such as
    /// `* LIST (\HasNoChildren \Sent) "/" "Elementos enviados"` into entries.
    /// Lines that are not mailbox data are skipped. Modified-UTF-7 names are
    /// decoded so a localized folder compares as the user sees it.
    public static func parseListResponses(_ lines: [String]) -> [MailboxListEntry] {
        joiningLiterals(lines).compactMap(parseListLine)
    }

    /// Folds IMAP literals (`... {10}` followed by 10 bytes on the next line or
    /// lines) back into one quoted line, consuming exactly the declared length,
    /// so the `{n}` marker is never mistaken for a mailbox name. Lines a literal
    /// spans (split at its embedded CRLFs) are re-joined with CRLF.
    private static func joiningLiterals(_ lines: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            guard line.hasSuffix("}"), let open = line.lastIndex(of: "{"),
                  let length = Int(line[line.index(after: open)..<line.index(before: line.endIndex)]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "+"))),
                  length >= 0 else {
                result.append(lines[index - 1])
                continue
            }
            var data = Data()
            while data.count < length, index < lines.count {
                if !data.isEmpty { data.append(contentsOf: Array("\r\n".utf8)) }
                data.append(contentsOf: Array(lines[index].utf8))
                index += 1
            }
            let literal = String(bytes: data.prefix(length), encoding: .utf8) ?? ""
            let escaped = literal.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            result.append(String(line[..<open]) + "\"" + escaped + "\"")
        }
        return result
    }

    private static func parseListLine(_ rawLine: String) -> MailboxListEntry? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("*") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let upper = line.uppercased()
        guard upper.hasPrefix("LIST ") || upper.hasPrefix("XLIST ") else { return nil }
        guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") else {
            return nil
        }
        let attributes = line[line.index(after: open)..<close]
            .split(separator: " ").map(String.init)
        var rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        // Hierarchy delimiter: a quoted char or NIL.
        if rest.hasPrefix("\"") {
            guard let end = rest.dropFirst().firstIndex(of: "\"") else { return nil }
            rest = String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        } else if rest.uppercased().hasPrefix("NIL") {
            rest = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }
        var name = rest
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
            name = name.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        guard !name.isEmpty else { return nil }
        return MailboxListEntry(attributes: attributes, name: ModifiedUTF7.decode(name))
    }
}

/// Decoder for IMAP's modified UTF-7 mailbox-name encoding (RFC 3501 5.1.3).
enum ModifiedUTF7 {
    static func decode(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            let char = input[index]
            guard char == "&" else {
                output.append(char)
                index = input.index(after: index)
                continue
            }
            let afterAmp = input.index(after: index)
            guard let dash = input[afterAmp...].firstIndex(of: "-") else {
                output.append(contentsOf: input[index...])
                break
            }
            let chunk = input[afterAmp..<dash]
            if chunk.isEmpty {
                output.append("&")
            } else {
                var base64 = chunk.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64.append("=") }
                if let data = Data(base64Encoded: base64),
                   let decoded = String(data: data, encoding: .utf16BigEndian) {
                    output.append(decoded)
                } else {
                    output.append(contentsOf: input[index...dash])
                }
            }
            index = input.index(after: dash)
        }
        return output
    }
}
