# Local data: what Sentwise stores, and how it is purged

Sentwise is local-first: mail content, the learned voice profile, and app state
live on the user's Mac, never server-side. This document describes where that data
lives, which parts are purged when an account goes away, and the "Erase all local
data" escape hatch (backlog item 96 / security finding A-L2).

## Where data lives

All non-secret state is JSON under `~/Library/Application Support/Sentwise/`,
written atomically by `PersistenceService` (the `PersistenceProvider` seam; the
in-memory `MemoryPersistenceProvider` backs Prowl hunts and tests). Secrets —
mailbox app passwords (per-account), managed-account Clerk tokens, BYO API keys —
live in the macOS Keychain via `KeychainStore`, never in the JSON files.

| File | Contents | Scope |
|------|----------|-------|
| `Settings.json` | App preferences, account identity, saved-account list, provider/managed config, signature, sender rules | **App-global config** (holds account identity, but not mail content) |
| `VoiceProfile.json` | Voice learned from the user's Sent mail | **Active-account / legacy unscoped** (mail-derived) |
| `ProcessedMessages.json` | Watcher dedup + per-mailbox baseline | **Account-scoped** |
| `PendingDrafts.json` | Full incoming message bodies + generated drafts awaiting review | **Account-scoped** |
| `SkippedMessages.json` | Sender + subject of messages the watcher passed over | **Account-scoped** |
| `ApprovedDrafts.json` | Approved-draft tombstone identities | **Account-scoped** (mail-derived) |
| `ActivityEvents.json` | Sender + subject per activity event | **Account-scoped** |
| `DraftFeedback.json` | Approval-signal codes/numbers/hashes (+ local deny "Other" free text) | **Account-scoped** (mail-derived) |

Most stores are keyed by account and are filtered on purge so removing one saved
account does not wipe another account's drafts, history, or watcher baseline.
`VoiceProfile.json` is the one legacy single-profile artifact: it is cleared when
the active account is disconnected/removed/purged, but an inactive saved-account
removal leaves the current profile intact. Older untagged draft/activity/feedback
records are treated the same way — cleared only during an active-account purge.
The two stores beyond the original A-L2 audit list, `ApprovedDrafts.json` and
`DraftFeedback.json`, are still purged with the matching account.

## Account-scoped purge

`AppState.purgeLocalMailArtifacts(for:includeUnscopedArtifacts:)` (in
`AppState+LocalDataPurge`) filters the target account's records through
`PersistenceProvider.purgeAccountScopedArtifacts(for:includeUnscopedArtifacts:)`
and clears the matching in-memory mirrors, leaving `Settings.json`, the Keychain,
and other saved accounts' records intact. The persistence operation is synchronous
and throwing on this path so a filesystem/write failure is surfaced instead of
logged as a successful privacy erase.

It is **offered**, not forced, so a routine reconnect does not destroy a user's
voice profile and drafts. Each teardown path presents a confirmation naming exactly
what will be deleted:

- **Disconnect** (`disconnectMail(purgeLocalData:)`) — a confirmation dialog offers
  "Disconnect & Erase Local Data" vs "Disconnect Only".
- **Remove saved account** (`removeSavedAccount(_:purgeLocalData:)`) — the removal
  alert offers "Remove & Erase Local Data" vs "Remove Only".
- **Delete managed account** (`deleteManagedAccount(purgeLocalData:)`) — the
  `DELETE`-gated sheet adds an "Also erase my local mail data on this Mac" opt-in,
  run only after the server-side deletion succeeds.

The purge runs only once the underlying teardown succeeds; a rollback (e.g. a
Keychain/settings write failure) leaves both the account and its data untouched.

### Dedup / re-add decision

A purge removes `ProcessedMessages.json`, which holds the watcher's dedup set and
its per-mailbox baseline. The deliberate decision is to **purge the dedup with the
account** and rely on the watcher's baseline to bound re-drafting: on the next
connect the watcher re-seeds a fresh baseline from the mailbox's current state
(`AppState+Watcher` treats everything at or older than the baseline as historical
and only drafts mail that arrives *after* it). A re-added account therefore does
**not** re-draft old inbox mail. The trade-off: a message that arrived while
disconnected and is still unactioned in the inbox at re-add time is folded into the
new baseline and won't be drafted — consistent with the product contract (Sentwise
drafts mail that arrives while it is connected and watching), and strictly better
than leaking the previous account's cached mail forward.

## Erase all local data

Settings → General → **Local data → "Erase all local data"** opens a typed-`DELETE`
confirmation (mirroring the delete-account sheet). `AppState.eraseAllLocalData()`:

1. removes **everything** under the Application Support directory (not just the
   known JSON files — the whole subtree, then recreates it empty),
2. clears **every** Keychain item via `SecretStore.removeAll()`, and
3. clears UserDefaults-backed local caches (subscription snapshot, usage-alert
   history, and the local "already offered Google OAuth" flag), and
4. disables launch-at-login and resets in-memory state to a coherent first-run
   state (disconnected, signed out, default preferences,
   `onboardingCompleted = false`) without a relaunch.

Before Keychain deletion, erase-all stops mail/transcript watchers, cancels
pending managed sign-in handles, and runs the normal managed sign-out path so an
existing Clerk session-revocation request is scheduled while the token still
exists. It returns a result containing any Application Support or Keychain
failure so the UI can keep the sheet open and describe the partial erase
precisely.

## Hunt / test safety

Both the purge and the erase run against the `PersistenceProvider` seam, so in
Prowl hunt mode (in-memory provider + in-memory secret store) they touch zero disk.
The new destructive controls carry stable AX identifiers and are forbidden in
`.prowl/config.yml` (`Erase`/`erase`, `disconnectOnly`, `removeAccountOnly`, plus
the existing `Disconnect`/`Remove `/`Delete` families), so hunts open-and-assert
these surfaces but never trigger a wipe.
