import Foundation

/// How a signature is applied to a generated draft (item 24).
///
/// Sentwise connects over IMAP + an app password, so it cannot read the
/// signature configured in Gmail's web UI (that lives in Gmail settings and is
/// never exposed over IMAP/SMTP). The user therefore chooses between no
/// signature and a custom one they type in (optionally seeded from their Sent
/// mail via `SignatureDetector`).
enum SignaturePolicy: String, CaseIterable, Equatable {
    /// No signature is appended to drafts.
    case none
    /// A free-text signature the user typed in is appended (unless the draft
    /// already ends with a signature block — see `SignatureApplier`).
    case custom

    /// The default for a fresh install and for files that predate the setting:
    /// append nothing until the user opts in.
    static let `default`: SignaturePolicy = .none
}
