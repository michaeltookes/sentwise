# CLAUDE.md

Guidance for agents working in the **sentwise** repository.

## What this is

Sentwise is a **native, local-first macOS menu-bar assistant** that learns the user's voice from their Sent mail and drafts email on their behalf. A native macOS notification alerts the user that a draft is ready and lets them open it; approval is a deliberate action in the Review Drafts window after reading the full draft (the notification banner can't show it in full — see item 79).

**Product rename (2026-08-13):** the product was renamed **Email Junkie → Sentwise** (a clean, pre-release break — no released builds existed, so there is no migration code for settings or Keychain). Canonical domain **sentwise.ai**; **sentwise.app** and **sentwise.io** are owned and redirect to it. The GitHub repo is renamed to `sentwise` at merge time. Bundle id is `com.tookes.Sentwise`; the local mail package is `SentwiseMail`.

**Direction update (2026-08-12):** the **flagship workflow is the post-call follow-up** — when a call ends, ingest the transcript and draft the next-steps email in the user's voice (backlog items 51–57). Inbox reply drafting remains, as one workflow among several. Primary commercial ICP: **Account Executives / high-velocity salespeople** (the "Marcus" persona in `docs/backlog.md`). **No bot, no storage, no training:** calls are never joined by a bot; audio and (future) capture/transcription stay on-device; call content is never stored server-side or used as training data. Drafting runs through a stateless, zero-retention managed proxy by default (2026-08-12 managed-inference decision — backlog items 56/59), or fully under user control via BYO-key/local model. (Bot-free capture alone is no longer unique — Fathom and Granola both offer it but store calls in their cloud and train on de-identified customer data; the durable differentiators are nothing-stored/nothing-trained-on privacy and the send-ready email in the user's voice from their own mailbox.)

It is a **Prompter-family product** — a native Mac app for individual knowledge-worker productivity — **not** part of the Prowl Tools (CLI-first developer SDLC) suite. Keep that identity clear: this is a private, on-device GUI app for busy professionals, not developer tooling.

### v1 design decisions
- **Platform:** native macOS menu-bar app (Swift), shipped via the Prompter pattern — signed/notarized DMG + Homebrew cask + Sparkle auto-update. **Affirmed over an Electron rewrite 2026-08-12**; Windows demand is measured via a landing-page waitlist (item 57) before any port is considered.
- **Approval channel:** native macOS notification first — it alerts that a draft is ready and opens the Review Drafts window (Open / Close only, no approve-from-banner); approval happens in that window (item 79). Slack is a future item.
- **Email provider:** Gmail first. Outlook/M365 and IMAP/SMTP are future items.
- **Send behavior:** user-configurable — auto-send on approve *or* save-as-draft.
- **LLM access:** pluggable provider architecture — **managed inference is the default** (bundled into the subscription, no keys; backlog item 56); BYO-any-provider and a local-model option (e.g. Ollama) remain as the power/privacy path (item 59). **56a shipped (2026-08-20):** the `.managed` provider (`LLMProviderKind.managed`, default for new installs; `ManagedInferenceClient`) drafts through the stateless **`sentwise-service`** Cloudflare Worker (`sentwise-inference`, deployed at `https://sentwise-inference.sentwise-service.workers.dev`) under a Clerk account session. Auth is **Clerk** (email-code sign-in via the Frontend API, implemented natively in the app — not the clerk-ios SDK; see `docs/managed-inference.md`); the model provider is the **Anthropic Messages API** (`claude-sonnet-4-6` default) under zero-data-retention terms; the 14-day trial is enforced server-side. Metering/caps (56b) and checkout/licensing (56c) are not built yet.
- **Ethos:** local-first, private. Mail data, voice profile, and (future) call audio stay on the machine; drafting inference leaves only as a stateless zero-retention call (managed default) or via the user's own key/local model. Secrets live in the macOS Keychain.
- **Monetization (updated 2026-08-12, second revision — supersedes "no subscription" and BYO-key-as-default):** subscription with **managed inference bundled** (user never touches an API key; stateless zero-retention proxy; license = account); open core / paid binary — source stays public, signed auto-updating binaries are licensed. Trial → Individual → Team; BYO-key/local stays as the power/privacy option. See backlog items 56–59. The landing page/marketing site lives in **its own repo** and requires a discussion before any building starts.

### Email connection method (updated 2026-07-03): IMAP + app password
**The primary connection path is IMAP + a Google app password**, implemented with SwiftNIO (`swift-nio-imap`) in the local `Packages/SentwiseMail` package. Users paste their email + a 16-character app password (2FA required) — no Google Cloud console, no client ID/secret, no verification/CASA.

This **superseded an earlier BYO-OAuth decision** (2026-07-02): we built the full Google OAuth flow (item 3) but live testing showed BYO OAuth is far too much friction for non-developers (create a Cloud project, enable APIs, configure a consent screen, make a Desktop client). The OAuth engine (`GmailAuthCoordinator`, `OAuthTokenService`, `LoopbackRedirectListener`, etc.) **remains in the codebase, parked** — it's the future "bundled verified client + CASA" option if the product ever targets the non-technical mass market. Known parked bug: the OAuth loopback listener throws `NWError 22` on start; unfixed because that path isn't primary.

We first tried **MailCore2** for IMAP but its SPM/arm64 distribution is abandoned (2020/2022 binaries), so we use Apple's `swift-nio-imap` instead. See [[oauth-byo-credentials-decision]] memory.

## Backlog Management

Active items live in `docs/backlog.md`; completed items live in `docs/resolved.md`.

**Conventions** (follow these exactly):
- Items use priority tiers (**High / Medium / Low**). New items are numbered sequentially after the highest existing number.
- **Item numbers are stable IDs.** They are not reused or renumbered when an item is completed — this keeps cross-references (e.g. "see item 10") and git history (commits that reference "item N") valid. A resolved tier may therefore start at a number other than 1.
- Each item has: a **bold title**, a one-line summary, a **user story** in *As a … I want … so that …* form, and **acceptance criteria** as a bullet list. We embed user stories directly in backlog items — do **not** create a separate user-stories file.
- Keep descriptions concise but complete enough for any agent to act without re-deriving intent.

When you **complete** work that corresponds to a backlog item, follow the `/update-backlog` skill:
- Move the item to `docs/resolved.md` using the strikethrough format: `### ~~N: Title~~`, with a `**Resolved**: YYYY-MM-DD (commit HASH or branch NAME)` line and a synthesized description of what was actually delivered.
- Remove the item's block from `docs/backlog.md`. Do **not** renumber the remaining items.

When you **discover** new bugs, tech debt, or feature opportunities:
- Read the backlog file and add the item to the appropriate priority tier (default **Medium** if unsure).
- Match the existing format: numbered, bold title, one-line summary, user story, acceptance criteria.

The `/update-backlog` skill automates matching commits to items — keep the file's format stable so it keeps working.

## Workflow rules

- **Never commit directly to `main`.** Branch first; ask for a branch name if one isn't given.
- **Never open pull requests** unless explicitly asked — commit and push to the branch only.
- Commit and push only when the user asks.
