# Approval-signal learning loop (item 83)

Sentwise treats what you do with each draft — approve it untouched, edit it
before approving, or deny it — as durable feedback about how well it drafts and
what it should surface at all. Phase 1 (this document) **captures** that signal
into an on-device store. Later phases read the store to tighten reply-worthiness
(Phase 2), tune the drafting voice (Phase 3), and surface a "how am I doing"
view (Phase 4); none of that learning is built yet.

Everything here is **local-first and on-device**. The store never leaves the
machine. Sending deny reasons off-device to improve product-wide drafting is a
separate, opt-in telemetry path (item 35) and is **not** part of this feature.

## The feedback store

Every reviewable draft ends in exactly one terminal action, and each records one
`DraftFeedbackRecord`. The store is a JSON file
(`~/Library/Application Support/Sentwise/DraftFeedback.json`) written through the
same persistence layer as pending drafts and the activity log, so it survives
relaunch. It is append-only, newest first, and capped at 2000 records (oldest
dropped) so it can't grow unbounded.

Each record holds **codes, numbers, and hashes only** — with a single exception,
the deny "Other" free text (below). In particular the draft is referenced by a
**SHA-256 hash of its identity string**, never the account address, subject,
body, or sender the identity is derived from.

| Field | Meaning |
| --- | --- |
| `timestamp` | When the terminal action happened. |
| `outcome` | `approvedAsIs` / `approvedAfterEdit` / `denied`. |
| `dispatch` | `sent` vs `saved` — approvals only. |
| `editMagnitude` | Normalized edit size in `0...1` — `approvedAfterEdit` only. |
| `denyReason` | Reason code (+ optional Other free text) — denials only. |
| `provenance` | `watcher` vs `manualPreview` (user-requested preview) vs `draftAnyway` (a "Draft anyway" skip-log override) vs `authored` (a user-started follow-up). |
| `answeredNeedsInfo` | Whether the user answered a `NEEDS_INFO` prompt (item 85) before this outcome. |
| `draftIdentityHash` | SHA-256 hex of the draft identity — never the raw identity. |

`approvedAsIs` vs `approvedAfterEdit` comes from item 19's `wasEdited`
(`originalBody != body`). Authored follow-ups record `authored` provenance,
skip-log overrides record `draftAnyway`, drafts explicitly generated from the
mail preview surfaces record `manualPreview`, and only automatic inbox-watch
drafts fall back to `watcher`. `watcher` is a single bucket today — item 68's
header-fetch-degradation diagnosis may later split it (a draft that slipped past
a *degraded* reply-worthiness check vs. a clean one), and
`DraftFeedbackProvenance` is where that refinement would land.

The approval signal is recorded only after a send or save succeeds. Queued
approvals share the dispatch choke point, including when an offline-queued
approval finally dispatches on reconnect; preview-sheet and legacy generated
draft approvals record the same signal immediately after their direct dispatch
paths succeed.

### Edit magnitude

For an edited approval, the magnitude quantifies how much you rewrote the draft
as the **normalized character-level edit-distance ratio**:

```
magnitude = levenshtein(a, b) / max(a.count, b.count)
```

where `a` and `b` are the original and final bodies with leading/trailing
whitespace trimmed and every internal whitespace run collapsed to one space.
Normalization means pure reflow/spacing changes register as ~zero, so the signal
tracks substantive content edits, not formatting churn. The result is clamped to
`0...1`: `0` = identical after normalization, `1` = a complete rewrite.
Character-level (rather than changed-line fraction) is deliberate — a one-word
fix inside a long paragraph reads as a small edit, not a whole changed line. The
exact Levenshtein path is capped; unusually large pasted edits use a bounded
linear approximation with a small resynchronization window, so separated sparse
edits stay small without letting post-dispatch feedback capture freeze the main
actor before approval cleanup. The metric is pure (`DraftEditMagnitude.ratio`)
and unit-tested.

## Deny-reason picker

Hitting **Deny** (or **Discard**, on an offline-queued or stale draft) presents a
single-select reason picker **before** the deny finalizes. The deny cannot
complete until a reason is chosen, and **Other** reveals a mandatory free-text
field the deny won't finalize while empty. **Cancel** aborts cleanly — the draft
stays queued and nothing is recorded.

Presets and their stable codes (never renamed — later phases and item 35 read
them):

| Reason | Code |
| --- | --- |
| Not worth replying | `not_worth_replying` |
| Wrong tone | `wrong_tone` |
| Wrong content | `wrong_content` |
| Handle later | `handle_later` |
| Other | `other` |

**Friction guard.** The picker pre-selects your last-used reason, and a
per-session **"Don't ask again this session"** checkbox makes subsequent denies
this app run reuse that reason silently (still recorded). The setting resets on
relaunch.

A notification's **Deny** action can't host the picker, so it opens the review
window with the picker — unless "don't ask again" is set for the session, in
which case it discards immediately with the remembered reason.

The activity history's existing **Denied** event gains the reason **code** in its
detail (code only). The **Other** free text is the one user-authored value in the
whole system: it is stored only in the feedback store — never in the activity
history, never logged — and it is capped before storage so a pasted blob cannot
make the feedback file or later rewrites unbounded. It is the value that must be
scrubbed before any future off-device telemetry send (item 35).

## Privacy summary

- The store and all capture stay on the Mac; nothing here leaves the machine.
- Records are codes/numbers/hashes only, except the deny "Other" free text, which
  is local-only.
- Draft identity is stored as a SHA-256 hash, never the address/subject/body.
- Off-device aggregation of deny reasons is a separate opt-in path (item 35),
  disclosed and gated, and out of scope for this feature.

## Prowl hunt mode

The deny/reason flow mutates state, so its confirm control (`denyReasonConfirm`)
is forbidden in hunt mode exactly as Deny is. The picker's option rows
(`denyReasonOption-<code>`), Other field (`denyReasonOtherField`), cancel
(`denyReasonCancel`), and don't-ask-again checkbox (`denyDontAskAgain`) carry
stable AX ids so a hunt can assert the pane where guardrails allow, and mutate
nothing until confirm. In hunt mode the store routes through the in-memory
persistence provider, so a hunt has zero disk side effects.
