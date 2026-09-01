import CryptoKit
import Foundation

/// The user's terminal action on a draft, treated as durable learning signal
/// (item 83, Phase 1). Every captured draft path ends in exactly one of these.
enum DraftFeedbackOutcome: String, Codable, Equatable {
    /// Approved without touching the assistant's generated body.
    case approvedAsIs
    /// Approved after the user edited the body (item 19's `wasEdited`).
    case approvedAfterEdit
    /// Discarded from the review queue.
    case denied
    /// A manually generated preview was closed without approval.
    case abandoned
}

/// What an approval did with the draft — the send-behavior split, recorded so the
/// signal distinguishes "good enough to fire off" from "good enough to file".
enum DraftFeedbackDispatch: String, Codable, Equatable {
    case sent
    case saved

    init(_ sendBehavior: SendBehavior) {
        self = sendBehavior == .autoSend ? .sent : .saved
    }
}

/// Where the draft came from, so Phase 2 can weight a deny by how the draft was
/// surfaced. `draftAnyway` is the user's explicit skip-log "Draft anyway"
/// override; `authored` is a user-started follow-up; `manualPreview` is a draft
/// the user explicitly generated from a message preview; `watcher` is an inbox
/// draft surfaced automatically.
///
/// **Seam (item 68):** watcher provenance is currently a single bucket. Item 68's
/// header-fetch-degradation diagnosis (a draft that slipped past a *degraded*
/// reply-worthiness check vs. a clean one) may later split `watcher` into finer
/// origins; this enum is the place that refinement lands.
enum DraftFeedbackProvenance: String, Codable, Equatable {
    case watcher
    case draftAnyway
    case authored
    case manualPreview
}

/// A stable, single-select reason the user gives when denying a draft (owner
/// decision 2026-08-28). Raw values are stable snake_case codes and must never
/// change — they are the substrate Phase 2 learning and item 35's opt-in
/// telemetry read. Only `.other` carries user-authored free text, which stays
/// strictly local (see `DenyReason`).
enum DenyReasonCode: String, Codable, Equatable, CaseIterable {
    case notWorthReplying = "not_worth_replying"
    case wrongTone = "wrong_tone"
    case wrongContent = "wrong_content"
    case handleLater = "handle_later"
    case other = "other"

    /// The picker presets in display order (Other last).
    static let presetsInDisplayOrder: [DenyReasonCode] =
        [.notWorthReplying, .wrongTone, .wrongContent, .handleLater, .other]

    /// The human-readable label shown in the reason picker.
    var displayTitle: String {
        switch self {
        case .notWorthReplying: return "Not worth replying"
        case .wrongTone: return "Wrong tone"
        case .wrongContent: return "Wrong content"
        case .handleLater: return "Handle later"
        case .other: return "Other"
        }
    }

    /// Whether choosing this reason requires the mandatory free-text field.
    var requiresFreeText: Bool { self == .other }
}

/// A deny reason as stored with the signal: a stable code plus, for `.other`,
/// the user's free text.
///
/// **Privacy:** `otherText` is the *only* user-authored value in the entire
/// feedback store — everything else is a code, number, or hash. It stays local:
/// it is written to the feedback store and nowhere else — never the activity
/// history, never a log line, and (item 35) it is the value that must be scrubbed
/// before any future off-device telemetry send.
struct DenyReason: Codable, Equatable {
    static let otherTextCharacterLimit = 500

    var code: DenyReasonCode
    /// Present (non-empty) only when `code == .other`.
    var otherText: String?

    init(code: DenyReasonCode, otherText: String? = nil) {
        self.code = code
        if code == .other {
            let trimmed = (otherText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.otherText = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.otherTextCharacterLimit))
        } else {
            self.otherText = nil
        }
    }
}

/// One durable record of a terminal draft action (item 83, Phase 1). The store is
/// the on-device substrate that Phases 2–4 and items 84/35 will read; Phase 1 only
/// captures it.
///
/// **Privacy model (load-bearing):** every field is a code, number, hash, or
/// boolean — with the single exception of `denyReason.otherText`, which is
/// user-authored free text kept only here. In particular `draftIdentityHash` is a
/// SHA-256 of the draft's identity string, never the email address, subject,
/// body, or sender it is derived from.
struct DraftFeedbackRecord: Codable, Equatable, Identifiable {
    var id: UUID
    /// When the terminal action happened.
    var timestamp: Date
    /// Approved-as-is / approved-after-edit / denied / abandoned.
    var outcome: DraftFeedbackOutcome
    /// Sent vs saved — set for approvals only, `nil` for non-approvals.
    var dispatch: DraftFeedbackDispatch?
    /// Normalized edit magnitude in `0...1` — set for `.approvedAfterEdit` only.
    /// See `DraftEditMagnitude` for the metric definition.
    var editMagnitude: Double?
    /// The reason code (+ optional free text) — set for `.denied` only.
    var denyReason: DenyReason?
    /// Watcher vs. manual preview vs. "Draft anyway" override vs. authored follow-up.
    var provenance: DraftFeedbackProvenance
    /// Whether the user answered a `NEEDS_INFO` prompt before this outcome
    /// (item 85's `Draft.wasAnswered`) — records the "answered-then-approved" case.
    var answeredNeedsInfo: Bool
    /// SHA-256 hex of the draft's `identity`. Never the raw identity (which
    /// contains the account email), and never any other message content.
    var draftIdentityHash: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        outcome: DraftFeedbackOutcome,
        dispatch: DraftFeedbackDispatch? = nil,
        editMagnitude: Double? = nil,
        denyReason: DenyReason? = nil,
        provenance: DraftFeedbackProvenance,
        answeredNeedsInfo: Bool,
        draftIdentityHash: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.outcome = outcome
        self.dispatch = dispatch
        self.editMagnitude = editMagnitude
        self.denyReason = denyReason
        self.provenance = provenance
        self.answeredNeedsInfo = answeredNeedsInfo
        self.draftIdentityHash = draftIdentityHash
    }

    /// Hashes a draft `identity` (`account|mailbox|uidvalidity|uid`) into a stable
    /// SHA-256 hex string so the record can correlate repeat actions on the same
    /// draft without ever storing the identity — which embeds the account email.
    static func hashedIdentity(_ identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
