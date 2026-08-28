# Backlog

Prioritized list of planned features, improvements, and technical debt for **sentwise** — a native, local-first macOS assistant that learns your voice from your Sent mail and drafts email on your behalf, then alerts you when a draft is ready so you can review and approve it in the app (item 79). Its **flagship workflow (2026-08-12 pivot)** is the **post-call follow-up**: when a call ends, ingest the transcript and draft the next-steps email in the user's voice. Inbox reply drafting remains, as one workflow among several.

**Product direction (updated 2026-08-12):**
- **Flagship workflow:** transcript in → next-steps follow-up email out, in the user's voice (items 51–55). The existing drafting → approval → send plumbing is reused; transcript acquisition is the new subsystem, phased: file/paste ingestion first (51), calendar awareness (52), platform APIs (53), native no-bot capture last (54).
- **Primary commercial ICP:** Account Executives / salespeople in high-velocity roles (see **Marcus** persona). Priya remains the persona for the inbox-reply workflow.
- **No bot, no storage, no training:** calls are never joined by a bot; audio and (future) capture/transcription stay on-device; call content is never stored on our servers or used as training data. Drafting inference runs through a **stateless zero-retention proxy** by default (see Monetization), or entirely under the user's control via the BYO-key / local-model escape hatch. **Competitive note (2026-08-12):** Fathom ships bot-free desktop capture and Granola always has — and cloud notetakers store calls indefinitely and train on (de-identified) customer data per their own policies. The durable differentiators are (a) privacy that's minimized *and* guaranteed — nothing stored, nothing trained on, plus a BYO/local tier where we're not in the loop at all — and (b) the workflow's back half: a **send-ready email in the user's learned voice, sent from their own mailbox**, not a summary stranded in a notetaker app.
- **Non-goals (2026-08-13, from the momentum.io teardown):** manager/exec-facing surfaces — coaching scorecards, team dashboards, CRO briefings, churn signals, call-clip libraries. Momentum.io (now Salesforce) owns that org-facing lane; our value flows to the **individual rep**, and the org benefits only indirectly via CRM logging (item 55). Agents should not drift features toward the manager persona.
- **Monetization (updated 2026-08-12, second revision — supersedes both "no subscription" and BYO-key-as-default):** subscription with **managed inference bundled** — the user never touches an API key or provider billing. Unit economics support it: a follow-up costs single-digit cents, so ~175 follow-ups/month ≈ $2–8 against a ~$15–20/mo subscription. Open core / paid binary — source stays public, signed auto-updating binaries are licensed; the license is an **account/sign-in** (needed for inference metering anyway). Trial → Individual → Team with CRM logging (items 55–56); Enterprise explicitly parked. **BYO-key / local-model remains as the power/privacy option** (items 58–59) — the plumbing exists, it serves Sam and heavy users, and it's the tier where call content never touches any server.

**v1 design decisions:**
- **Platform:** native macOS menu-bar app (Swift), following the Prompter distribution pattern (DMG + Homebrew cask + Sparkle auto-update). **Affirmed over an Electron rewrite 2026-08-12** — validate on macOS first (the ICP skews Mac); measure Windows demand via a landing-page waitlist (item 57) and revisit Tauri/Electron only if it fills.
- **Approval channel:** native macOS notification first — it alerts that a draft is ready and opens the Review Drafts window (Open / Close only); approval is a deliberate in-app action there (item 79). Slack as a peer channel is item 30 (post-launch).
- **Email provider:** Gmail first. (Outlook/M365 and IMAP/SMTP are future items.)
- **Send behavior:** user-configurable — auto-send on approve *or* save-as-draft.
- **LLM access:** pluggable provider architecture — **managed inference is the default** (bundled, no keys; item 56); BYO-any-provider and a local-model option remain as the power/privacy path (item 59).
- **Ethos:** local-first, private. Mail data, voice profile, and (future) call audio stay on the user's machine; drafting inference leaves only as a stateless, zero-retention call — via the managed proxy by default, or the user's own key / local model. *(The original "no subscription" and BYO-key-by-default clauses were superseded 2026-08-12 — see Monetization above.)*

**Personas referenced in stories below:**
- **Marcus — Account Executive, high-velocity sales (primary commercial ICP).** Runs 4–8 calls a day on Zoom/Meet/Teams from a company MacBook. Post-call admin — follow-up emails, CRM logging — eats 30+ minutes daily. Expenses $15–20/mo tools without blinking; his manager cares that activity lands in the CRM. May already use a notetaker (Fathom/Granola/Otter) — those transcripts are an ingestion source, not competition.
- **Priya — busy technical professional.** A Solutions Architect. Comfortable installing a signed Mac app and pasting an API key, but does *not* want to run servers or babysit a CLI. Lives in email; wants drafts waiting so she can triage in seconds. Cares about privacy and control.
- **Sam — self-hoster / privacy maximalist (secondary).** Wants everything local, will run a local model, may bring their own Google Cloud credentials. Values openness and "no data leaves my machine."

> **Item format:** every item has a bold title, a one-line summary, a user story (*As a … I want … so that …*), and acceptance criteria. See `CLAUDE.md` for backlog conventions.

---

## High Priority

> Resolved items are recorded in [`resolved.md`](./resolved.md). Item numbers are stable IDs — they are not reused or renumbered when items are completed.

> **Launch plan (owner decision 2026-08-20) — the High tier is ordered for a paid public launch:** 56 (managed inference — top priority) → 59 (sign-in-and-go onboarding, depends on 56a) → 66/67 + 69 (first-hour experience) → 24 (signatures) → 61 (live loop observed) → 71 (README/quickstart) → 73 (account pane) → 72 (legal/policy/support, in parallel with 56c) → 75 (Workspace app-password guidance) → 57 (landing page + checkout, in its own repo) → 74 (clean-Mac verification + 1.0 release, closes last). Slack (30), native capture (54), and the transcript test plan (70) are deliberately **deferred** until after launch feedback.

56. **Licensing, billing, and the managed-inference service (open core / paid binary)** — *⬆️ TOP PRIORITY (owner decision 2026-08-20)*
    > **Decision 2026-08-20:** launch **with** managed inference, not BYO-key-only. Rationale: the primary ICP (Marcus) has never heard of an API key and a key-paste in onboarding deters exactly the first-time users we need; bundling inference also lets the product charge from day one. BYO-key/local remains the escape hatch (item 59), never the default. The beta-with-technical-users shortcut was considered and rejected.
    The monetization plumbing behind the 2026-08-12 pricing decisions: public source, licensed binaries, subscription checkout, and — per the managed-inference decision — the stateless proxy that bundles drafting into the subscription so users never touch an API key.
    *As the maintainer, I want people to pay one price that includes the AI, so that non-technical buyers convert without becoming an LLM customer somewhere else; as Marcus, I want nothing to set up or pay for beyond the subscription itself.*
    - **Open core / paid binary:** source stays public on GitHub (self-compilers welcome); the signed, notarized, Sparkle-updating binary requires a license. The license is an **account/sign-in** (required for inference metering anyway).
    - **Managed-inference proxy:** app → serverless proxy → model provider. **Stateless by design** — no storage, no content logging, request/response held in memory only — under **zero-retention terms** with the provider. This design is load-bearing for the "no storage, no training" claim and must be verifiable in the public source.
    - **Metering & margin protection:** per-account token metering, rate limits, and abuse prevention; margin monitoring for the maintainer; a **fair-use policy in the pricing terms from day one** so heavy users don't silently eat the margin — with "switch to your own key for unlimited" (item 59) as the pressure-release valve.
    - Full-featured **trial** (14 days or first N calls — exact mechanic TBD); trial state survives reinstall reasonably.
    - **Individual** tier ~$15–20/mo or annual equivalent, **inference included** (unit cost is single-digit cents per follow-up); **Team** tier (3+ seats, adds CRM logging — item 55 — and centralized billing) as a follow-on; Enterprise explicitly parked.
    - Checkout via a **merchant-of-record** (Paddle / Lemon Squeezy class) so a solo maintainer isn't handling global sales tax; in-app license validation with an offline grace period (drafting may need the network; the app must not brick offline).
    - Final pricing, trial mechanics, and provider choices to be settled in the item 57 pre-build discussion.
    - **Phasing (added 2026-08-20):**
      - ✅ **56a — Account + proxy (unblocks onboarding)** — *Done 2026-08-20; merged to `main` 2026-08-21 via PR #54 (`b2be2b8`) (app branch `managed-inference`; service repo `sentwise-service` branch `managed-inference`, deployed `https://sentwise-inference.sentwise-service.workers.dev`).* Delivered: the stateless `sentwise-service` Cloudflare Worker (`POST /v1/draft`, `GET /v1/me`, `GET /healthz`) verifying a Clerk session JWT and forwarding to the Anthropic Messages API under zero-retention terms, with the 14-day trial stored server-side in Clerk `privateMetadata` and no request/response body logging (CI-guarded); the app-side `LLMProviderKind.managed` provider (default for new installs) + `ManagedInferenceClient`; native Clerk Frontend-API email-code sign-in (`ClerkClient`/`ManagedAccountService`, chosen over the clerk-ios SDK — see `docs/managed-inference.md`); settings migration 14→15 (unconfigured installs move to managed, BYO users keep theirs); managed-first onboarding + Settings UI with BYO behind a subdued disclosure; and a Prowl hunt-mode stub (zero network). Google sign-in deferred within 56a. **Live-verified end-to-end 2026-08-20/21 by the owner:** native email-code sign-up/sign-in against the real Clerk instance (after turning off Clerk's password requirement), then a "Draft anyway" generation from Review Drafts produced `POST /v1/draft → 200` on the Worker (3.2 s, no exceptions, no logs, Authorization redacted in tail) — first managed draft, trial clock started. Original scope for reference: sign-in (magic-link/OAuth via a hosted auth provider), a stateless serverless proxy that accepts the app's session token and forwards drafting requests to the model provider under zero-retention terms, and an `LLMProvider` implementation in the app (`ManagedInferenceClient`) selected by default. Trial state lives server-side against the account. Ships in its own repo (`sentwise-service`) with the proxy's no-storage design readable in public source. Prowl hunt mode stubs the managed client (no network) so hunts stay offline-safe.
      - **56b — Metering + limits:** per-account token metering, daily/monthly caps with the fair-use policy, rate limiting, abuse controls, margin dashboard for the maintainer; the app shows remaining allowance and the "switch to your own key for unlimited" valve.
      - **56c — Checkout + licensing:** merchant-of-record checkout (Paddle / Lemon Squeezy), subscription state synced to the account, in-app license check with offline grace, trial → paid → lapsed states handled in the UI; Team tier deferred.
    - **Decisions made 2026-08-20 (owner-approved defaults):** auth = **Clerk** (Free tier through build/dogfood; upgrade to Pro ~$20/mo just before public launch to drop Clerk branding/custom emails); proxy host = **Cloudflare Workers**; model provider = **Anthropic API** under the zero-data-retention agreement (confirm terms in writing before item 72's privacy policy; OpenAI-compatible route kept as fallback); trial = **14 days, full-featured, server-side**; price = **$19/mo or $180/yr Individual**; MoR = **Paddle** (Lemon Squeezy fallback); service repo = **`sentwise-service`**. Clerk account created 2026-08-20.
    - **Open implementation check for 56a:** Clerk's native SDK is iOS-first — verify macOS support vs. using the Frontend API / hosted sign-in hand-off from the Mac app before committing to the sign-in UX.

3. **Gmail connection (OAuth)** — *PARKED (superseded by item 32 as the primary path); engine kept for a future bundled-client option*
   > **Parked 2026-07-03:** BYO OAuth proved too high-friction for non-developers, so IMAP + app password (item 32) is now the primary connection path. The OAuth engine stays in the codebase for a possible future "bundled verified client + CASA" revival. Known parked bug: loopback listener throws `NWError 22` on start. The ✅ items below are built; the ⬜ items are only relevant if OAuth is revived.

   Authenticate to Gmail with the minimum scopes needed to read inbox + Sent and create/send replies. **Distribution model (decided 2026-07-02, later superseded): bring-your-own credentials with pluggable client config. See CLAUDE.md.**
   *As Priya, I want to connect my Gmail, so that the assistant can read my mail and draft replies.*
   *As Sam, I want to supply my own Google Cloud OAuth client, so that I authorize the app under my own project with no shared-client caps or verification.*
   - ✅ PKCE desktop/loopback flow requesting only `gmail.modify` + `gmail.send`; authorization URL, code exchange, and refresh all built and unit-tested.
   - ✅ User supplies their own client ID/secret in Settings; client config is pluggable so a bundled client can be added later.
   - ✅ Tokens + client credentials stored in the macOS Keychain (item 10); access token auto-refreshes on expiry.
   - ✅ Connected-account indicator and a "disconnect" action in Settings (disconnect clears the token, keeps credentials).
   - ⬜ **Remaining:** verify the live end-to-end consent flow against a real Google client; **empirically verify refresh-token lifetime** (Testing vs Production) and document the setup so users avoid weekly re-auth; optionally show the connected account's email address; consider server-side token revocation on disconnect.

57. **Landing page / marketing site** — *⚠️ discussion required before building; lives in its own repo*
    The public site where people find the product, understand it in 30 seconds, and pay: positioning, pricing/checkout, download, and the Windows-demand waitlist.
    > **Do not start building from this item.** Scope, stack, hosting, domain, and copy need a dedicated discussion first, and the site goes in **its own repository**, not sentwise. This item exists so the work isn't forgotten and its requirements are captured.
    *As Marcus, I want to find the product, get what it does in 30 seconds, and start a trial without friction, so that trying it is easier than ignoring it.*
    - Positioning centered on the post-call follow-up workflow ("your follow-up is drafted before you're back from coffee") and the differentiators: no bot in your meetings, nothing stored in anyone's cloud, never training data, one price with the AI included.
    - **Training-data contrast (updated 2026-08-12 for the managed-inference decision):** cloud notetakers' own policies state customer call data (de-identified) is used to improve their models — e.g. Fathom's FAQ — and they store calls indefinitely. Our claim, stated accurately and without overreach: **"your calls are never stored on our servers and never train anyone's models"** — the managed proxy is stateless with zero-retention provider terms (item 56), and the BYO-key/local path removes us from the loop entirely. Copy must not blur the tiers: "we never even see your calls" belongs to the BYO/local option only.
    - Pricing page and checkout wired to the item 56 licensing/billing flow; prominent trial/download CTA.
    - **"Windows — join the waitlist"** email capture — the demand probe that decides if/when a cross-platform port (Tauri/Electron) is justified.
    - **Feedback form (moved here from item 36, 2026-08-26):** a small "send feedback / feature request" form for site visitors and general (non-bug) feedback the maintainer can triage into the backlog. Complements — does not replace — the in-app "Report a Problem" path (item 36), which owns bug reports because only the app can produce the redacted diagnostic log bundle (a web form can't). The app may deep-link to this form with app/macOS version prefilled. Needs a form backend/service; scope with the rest of the site.
    - Basic discoverability: SEO fundamentals, OG/social cards, and a home for a demo video.
    - Held in a separate repo with its own deployment; all stack/hosting/analytics decisions deferred to the pre-build discussion.

72. **Legal, policy, and support foundations for a paid launch**
    A paid product with sign-in needs the documents and channels the rest of the stack depends on: the merchant-of-record won't enable checkout without Terms and a Privacy Policy, the auth provider links to them, and the "no storage, no training" claim needs a written policy behind it.
    *As a prospective customer, I want to read exactly what Sentwise does with my mail, my calls, and my payment, and know how to get help, so that I can trust a small company with my inbox.*
    - **Privacy Policy** that is accurate to the architecture: what stays on the Mac (mail, voice profile, transcripts), what transits the proxy and under what retention terms (none), what the account stores (email, subscription, usage counters — never content), Slack caveat if/when item 30 ships.
    - **Terms of Service** incl. the **fair-use policy** referenced by item 56b, refund policy, and trial terms; reviewed against the MoR's requirements.
    - **Security page / disclosure contact** (security@) and a short "how we handle your credentials" explainer (Keychain, app passwords, no server-side mail credentials).
    - **Support channel:** support@sentwise.ai mailbox with a stated response expectation, linked from the app (item 36) and the site (item 57).
    - Hosted on the sentwise.ai domain (with item 57 or a minimal static page before it); versioned in a repo so changes are reviewable.

73. **Account & subscription pane in Settings**
    With an account behind the app (item 56), the user needs one place to see and manage it; today Settings has no notion of an account at all.
    *As Marcus, I want to see my plan, trial days left, and usage, and fix billing or sign out without hunting, so that the subscription never feels like a black box.*
    - Sign in / sign out; shows account email, plan (Trial / Individual), trial days remaining or renewal date.
    - Usage this period vs. allowance (from item 56b) with the "switch to your own key for unlimited" link into the item 59 power path.
    - "Manage billing" opens the MoR customer portal; lapsed/past-due state explained with a clear call to action; the app degrades gracefully (BYO-key still works, managed drafting pauses with a reason shown).
    - **Delete account** (server-side data removal incl. usage counters; local data untouched unless the user also chooses to reset) — required for a credible privacy posture.
    - Lives as a toolbar tab in the native Settings window (item 65); Prowl hunt-safe AX identifiers, disabled/stubbed in hunt mode.

74. **Launch readiness: clean-Mac verification, security pass, and the 1.0 release**
    The last item to close before inviting the public. Every release so far was tested on the maintainer's own configured Mac; a stranger's experience — Gatekeeper, fresh Keychain, no prior Application Support, TCC prompts — has never been observed.
    *As the maintainer, I want proof that a first-time user on a clean Mac gets from download to first draft without help, so that launch day isn't debugging day.*
    - **Clean-machine run** (fresh macOS user account or VM): DMG install via browser download (Gatekeeper/notarization path), `brew install --cask` path, first-run onboarding with sign-in/trial + Gmail app password, voice learn, first inbox draft, first transcript follow-up, approve via notification, Sparkle update from the previous version. Every friction point logged as a backlog item.
    - **Security pass** via `/security-review` on the app and the service repo: token handling, proxy auth, Keychain usage, log redaction, dependency audit.
    - **Release hygiene:** version **1.0.0** via `/release-prep`; CHANGELOG written for humans; cask and appcast verified from a machine that isn't the maintainer's; GitHub release notes link the quickstart (item 71).
    - **Feedback inbox live:** the `feedback@sentwise.ai` address wired into the app's "Report a Problem" (item 36) must be a real, monitored mailbox before launch (Google Workspace setup) — the app ships the address regardless, but a stranger's feedback must actually reach the maintainer.
    - Launch checklist recorded in `docs/` and ticked; this item closes when the public link goes out.

75. **Google Workspace accounts where app passwords are disabled**
    The primary ICP works on a company Google Workspace account, and many Workspace admins disable app passwords (or enforce security keys), which makes the IMAP + app-password path (item 32) fail outright — exactly the user we're launching for. Today this surfaces as a generic authentication error.
    *As Marcus on a company Workspace account, I want Sentwise to tell me plainly when my admin has disabled app passwords and what my options are, so that I don't conclude the app is broken.*
    - Detect the Workspace-specific IMAP failure modes (app passwords disabled, IMAP disabled by admin, 2-Step Verification not enrolled) and show targeted guidance in onboarding/Settings instead of a generic error, reusing the item 43 `CredentialGuidance` pattern.
    - Offer the user a one-line "Ask your admin" message to forward, and a **"notify me when sign-in-with-Google is available"** capture so demand for reviving the bundled OAuth client + CASA path (parked item 3) is measured, not guessed.
    - Record the failure class in activity history (no credentials) so the maintainer can see how often launch users hit it.
    - Decision checkpoint recorded after launch: if a meaningful share of sign-ups hit this, un-park item 3.

## Medium Priority

82. **Review Drafts as a collapsible list (fix scroll-capture; row → expandable detail)**
    The Drafts tab stacks full draft cards, each nesting an incoming-message `ScrollView` and a reply `TextEditor`; those inner regions capture the scroll wheel, so the outer list only scrolls when the cursor is over the thin strip between them ("you have to be in the middle to scroll"). Replace the stack with a clean scrollable list (like the Browse Mailbox window); clicking a row expands the existing detail card inline, collapsible back.
    *As Priya, I want to scroll my drafts smoothly and expand just the one I want to read, so that reviewing drafts isn't a fight with nested scroll areas.*
    - The Drafts tab renders as a scrollable **list of rows** (sender, MIME-decoded subject per item 69, and a status chip: Ready / Needs info / Add recipients). The list is the primary scroll surface and scrolls from anywhere in it.
    - Clicking a row **expands it inline** to the existing detail (incoming ↔ proposed reply, inline recipient edit, body edit, Deny/Approve); clicking again or a chevron **collapses** it. Default: **one row expanded at a time** (accordion).
    - All current behaviors preserved: approve/deny, inline recipient edit (item 51), body edit (item 19), needs-info flag (item 13), stale-thread warning (item 12), notifications-off banner (item 78), auto-send undo (item 23). The expanded reply editor's own scroll stays contained.
    - Prowl: rows and the expand/collapse control get AX identifiers; the expand toggle is a read-only view toggle (like `reviewDraftsTab`, item 69) and is **not** forbidden — document in `.prowl/README.md`; no collision with existing forbidden selectors.
    - Sets up **item 76** (search & filter): the list is the surface a filter field sits on. Consider applying the same list treatment to the Skipped tab for consistency (optional in v1).

76. **Search & filter the Review Drafts list**
    Let the user find a specific draft (or skipped message) without scrolling the whole list.
    *As Priya, I want to search and filter the Drafts and Skipped lists, so that I can find the message I'm looking for without scrolling past dozens of entries.*
    - A search field on the Review Drafts window filters the visible tab (Drafts and Skipped) by sender name/address and subject as the user types; clearing it restores the full list.
    - Match is case-insensitive and runs against the MIME-decoded subject (item 69), not the raw encoded-word header.
    - Optional lightweight filters on the Drafts tab (e.g. flagged / needs-info vs. ready) if cheap; the primary requirement is text search.
    - The counts on the tab labels reflect the filtered result (or show "N of M") so it's clear a filter is active.
    - Empty-result state shows a clear "No matches" message rather than a blank pane.
    - Prowl: the search field is open-and-assert forbidden (it's an input, not an action) and gets an AX identifier; no collision with existing forbidden selectors.

30. **Slack approval channel** — *spec expanded 2026-08-20; deferred to post-launch (Medium) by the 2026-08-20 launch decision*
    Post each ready draft to Slack with Approve/Deny actions as a peer of the native macOS notification, so approval works from any device the user has Slack on.
    *As a Slack-native user, I want drafts posted to Slack with approve/deny actions, so that approval fits my existing workflow.*
    - **Transport: Slack Socket Mode.** A local-first app has no public URL for Slack's interactive-component callbacks, so the Mac holds a persistent WebSocket (`apps.connections.open` with an app-level `xapp-` token) and receives button payloads over it. Envelopes are acked within Slack's 3 s window; reconnect with backoff on drop; while disconnected the native notification path is unaffected.
    - **Setup (opt-in, Settings → new "Slack" section):** the repo ships a Slack **app manifest** (`docs/slack-app-manifest.yml` — Socket Mode + interactivity on; bot scopes `chat:write`, `im:write`; app-level scope `connections:write`) so the user creates the app with one paste. They enter the bot token (`xoxb-`), the app-level token (`xapp-`), and a destination (channel ID or "DM me"); tokens live in the Keychain via `SecretStore` (`slack.botToken`, `slack.appToken`). A **Test** button posts a hello message. Settings schema 14 → 15.
    - **Message:** Block Kit mirroring the native notification — sender/recipients, subject, a bounded preview of the proposed reply, and buttons **Approve** (title reflects send behavior via `NotificationService.approveActionTitle(for:)`: "Send" vs "Save to Drafts"), **Deny**, **Open in Sentwise** (custom URL scheme → review window). Needs-info and recipient-needed drafts post with only "Open in Sentwise", matching the native notification categories.
    - **Routing:** introduce an `ApprovalChannel` abstraction so native notifications and Slack are peers. Slack actions map onto the existing `DraftNotificationAction` (`approve(sendBehavior)` / `deny` / `open`) and flow through `AppState.handleNotificationAction`, so every guard (unsaved inline edits, stale-thread warning, auto-send undo countdown) applies identically. The cases that today open the review window instead of acting reply in the Slack thread with "Open Sentwise to review this one" rather than silently doing nothing.
    - **Lifecycle sync:** draft identity ↔ Slack message `ts` mapping is persisted. Approving/denying in either channel updates the Slack message to a terminal state (✅ Sent / 📝 Saved to Drafts / ❌ Discarded / ↩️ Undone) and clears the native notification, and vice-versa; regeneration replaces the preview in place.
    - **Privacy disclosure:** posting draft text to Slack puts mail content on Slack's servers — the one channel that breaks "nothing leaves the machine" — so the opt-in copy says so plainly, and a **metadata-only mode** (sender + subject + buttons, no body) is offered. Default off; disabled in Prowl hunt mode.
    - **Tests:** Socket Mode client against a fake WebSocket server (connect, ack, reconnect on `disconnect` envelope), Block Kit payload builder snapshots, action-routing parity (every `DraftNotificationAction` path reachable via Slack), lifecycle-sync, and a headless live test gated on `SENTWISE_SLACK_TEST_*` env vars that posts to a private test channel and round-trips an approve.

70. **Transcript → follow-up (item 51) test plan and dogfood** — *2026-08-20; prerequisite for judging items 53/54*
    Item 51 shipped with ~100 unit tests but no realistic fixture corpus, no end-to-end test, and no live verification. Before building capture (54) or platform pickup (53), prove the existing paste/file/watched-folder path produces send-worthy follow-ups from real-world transcripts.
    *As Marcus, I want confidence that whatever transcript my tools export turns into a correct, sendable follow-up, so that I can trust the workflow on a real deal.*
    - **Fixture corpus** under `Sentwise/SentwiseTests/Fixtures/Transcripts/` with realistic sales-call content: Zoom VTT export, Teams VTT (`<v Name>` tags), Granola/Fathom Markdown, Otter `.txt`, SRT, an unlabeled transcript, a ~2-hour transcript (forces `TranscriptChunker`), plus edge cases — BOM/CRLF, empty file, unsupported extension, a file still being written (exercises `PendingFileStability`), Zoom's nested `~/Documents/Zoom/<date> <title>/` folder layout.
    - **End-to-end test with a fake LLM and fake mail provider:** file → `TranscriptParser` → `FollowUpGenerator` → pending draft → approve → dispatched to recipients with no threading headers; and the watched-folder variant on a real temp directory.
    - **Headless live test (QA preference — no click-throughs):** env-gated XCTest against the live Gmail account and a real LLM key: ingest a fixture → generate → save-as-draft → verify via IMAP that the draft exists in Drafts with the expected recipients/subject → delete it. Skips cleanly when the env vars are absent.
    - **Output quality rubric** applied to the fixture corpus (initially by hand, later an LLM-judge eval): accurate recap, next steps with owners, no invented commitments, proposed next meeting only when the transcript supports one, voice-profile match.
    - **Prowl hunt depth:** add a deterministic **fake LLM provider to hunt mode** so a hunt can seed a transcript into the hunt-mode watched folder and assert a "Review Drafts (2)" menu item / pending follow-up appears — the first hunt that goes beyond open-and-assert; requires a scoped relaxation of `forbiddenSelectors` documented in the README. *Partial (2026-08-21, branch `sign-in-onboarding`): the beyond-open-and-assert hunt infrastructure now exists — a deterministic offline fake for the item-59 sign-in/provider flows (`AppState+ProwlHuntAuth.swift`), five new hunts (`ai-provider-controls`, `managed-signin-email`, `managed-signin-google`, `openrouter-connect`, `settings-window-tabs`), a safe scoped `forbiddenSelectors` relaxation documented in `.prowl/README.md`, and an env-gated live Clerk sign-in test (`ClerkLiveSignInTests`, `+clerk_test`/`424242`). The transcript→watched-folder→"Review Drafts (2)" hunt itself is still to do; it can reuse this fake-in-hunt-mode + guardrail pattern.*
    - **Owner dogfood script:** five real-call scenarios (Zoom local recording → watched folder; Granola export → drag-drop; Teams VTT → file picker; paste from a notetaker; a call with no clear next steps) with expected outcomes, run and notes captured before items 53/54 start.

68. **Diagnose GitHub-notification draft leak + surface header-fetch degradation**
    Two GitHub PR notifications were drafted on 2026-08-20 even though GitHub mail carries `List-Id`/`List-Unsubscribe` headers that the (demonstrably working) bulk check should catch. Either the per-message header fetch failed silently — `fetchReplyWorthinessHeaders` degrades to sender-only evaluation on any error, logged but invisible to the user — or the drafts came from a manual "Draft anyway" override, which the activity log doesn't distinguish from watcher drafts.
    *As Priya, I want to trust that a draft in my review queue means the filters really passed it, so that a silent degradation doesn't quietly turn junk filtering off.*
    - Reproduce the GitHub-notification case (headless XCTest against the live account, per QA preference) and fix the root cause if it's a fetch/parse bug.
    - `draftCreated` activity events record their origin (watcher vs. forced override) so leaks are diagnosable after the fact.
    - Repeated header-fetch failures surface visibly (watch status or activity log), not just in the unified log.

20. **Voice profile refresh / re-learn**
    Keep the profile current.
    *As Priya, I want to re-learn my voice on demand or on a schedule, so that drafts keep up as my style changes.*
    - A "re-learn" action re-samples Sent and updates the profile.
    - Optional scheduled refresh interval in Settings.
    - Previous profile replaced atomically; a summary of changes shown.

22. **Cost & rate guardrails for cloud LLMs**
    Prevent surprise bills. *(Scope note 2026-08-12: with managed inference as the default, this item now serves the BYO-key escape hatch; the managed tier's metering and fair-use enforcement are server-side under item 56.)*
    *As Priya, I want usage limits and cost visibility for cloud providers, so that BYO-key drafting never surprises me.*
    - Token/usage tracked per run and per day.
    - Configurable caps pause drafting when exceeded, with a clear notification.
    - Estimated cost visible in the activity log/settings.

25. **Voice-profile cold start**
    Graceful behavior when there's little or no Sent history.
    *As a new user, I want sensible drafts even before the app has learned much, so that an empty Sent folder doesn't break onboarding.*
    - Detects sparse/empty Sent history and falls back to a sensible neutral profile.
    - Communicates that voice will improve as more mail is sent and on re-learn (item 20).
    - Never blocks onboarding (item 2) on insufficient history.

26. **Quiet hours / notification batching**
    Don't interrupt at night; optionally batch drafts.
    *As Priya, I want quiet hours and batched notifications, so that the assistant doesn't ping me at 2am or one message at a time.*
    - Configurable quiet-hours window during which notifications are suppressed and queued.
    - Optional batching so multiple ready drafts surface together rather than individually.
    - Queued drafts are delivered when quiet hours end.

28. **Accessibility of the approval UI**
    Make the core loop usable for everyone.
    *As a keyboard/VoiceOver user, I want to review and approve drafts without a mouse, so that the app is usable for me.*
    - Popover and approval UI are fully VoiceOver-labeled and keyboard-navigable.
    - Approve/deny/edit actions have keyboard shortcuts.
    - Respects system Dynamic Type, contrast, and reduce-motion settings.

46. **Mailbox monitoring view (clutter breakdown by sender and age)**
    A summary of what is actually piling up in a mailbox, so the biggest sources of clutter are obvious before cleaning. Split out of item 42, which delivered the bulk-cleanup engine but deliberately deferred this reporting view.
    *As a user with a huge, neglected inbox, I want to see which senders and which date ranges account for most of my unread mail, so that I know what to clean up instead of guessing at filters.*
    - **Total/unread counts** for the selected mailbox, obtained without downloading it.
    - **Breakdown by sender/domain** — the top senders by message count, so a single newsletter flooding the inbox is immediately visible.
    - **Breakdown by age** — buckets (e.g. last 7 days, 30 days, this year, older) so stale mail is easy to spot.
    - **Never bulk-download:** counting must reuse item 42's bounded `SequenceWindow` walk (or IMAP `ESEARCH COUNT` where supported) so a mailbox of any size stays safe. A partial/capped scan must be labelled as such rather than presented as exact.
    - **One-click hand-off:** selecting a row (a sender, or an age bucket) fills the browser's filter so item 42's preview + confirm cleanup can act on it directly.
    - Ties to reply-worthiness filtering (item 17) for what counts as "junk," and to the activity log (item 21) for an audit trail. Open question still outstanding from item 42: whether any cleanup should ever run automatically vs. manual-only.

50. **Durable offline-queue dispatch intent across relaunch**
    An approved-while-offline draft's send/save intent should survive an app restart, so approval means "done" even if the user quits before reconnecting. Follow-up to item 27, whose merged implementation keeps the queued intent (send behavior + force flag) in memory only — the draft itself survives relaunch in the pending store, but its approved dispatch intent is forgotten.
    *As Priya, I want a reply I approved while offline to still dispatch automatically after I relaunch the app and reconnect, so that I never have to re-approve something I already decided.*
    - The queued dispatch intent (draft identity, send behavior, force flag) persists locally via `PersistenceService`, with rollback if the write fails.
    - On launch, persisted intents are restored; reconnect drains them through the normal approval path so all no-duplicate-send guards (item 27) still apply.
    - Deny, successful dispatch, account switch, and disconnect clear the persisted entry.
    - Note: a pre-review prototype of exactly this exists in `stash@{0}` (2026-08-06, includes `AppStateOfflineQueueReviewFeedbackTests`), but it predates the merged review-feedback rework — re-implement against current `main` rather than popping the stash.

58. **Model-consistency harness + eval suite for the follow-up pipeline**
    Engineering consistency across model paths. The managed-inference default (2026-08-12 decision) narrows the primary surface to one or two curated models we choose — but the harness still governs the BYO-key/local escape hatch, honest quality signaling on weaker local models, and safe swaps of the managed default as providers evolve. **Sequenced after item 51's first working version** — build 51 against the managed default, then grow the harness from the variance actually observed, not speculation.
    *As Marcus, I want the follow-up to be reliably good on the default; as Sam, I want it reliably good on whichever model I brought — so that approval is a tap, not a rewrite session.*
    - **Staged pipeline, not one big prompt:** extract action items/decisions into a structured intermediate (JSON) → build recap → render the email in the user's voice; defined input/output contracts per stage so model variance is contained, not compounded.
    - **Deterministic post-generation validation** (code, not the model): structure valid, action items present, length in bounds, no invented recipients, signature policy respected. Failure → retry with feedback, or a visible low-confidence signal in the approval UI.
    - **Per-model capability adaptation:** context-window size, structured-output/tool-calling support, instruction-following tier detected and adapted to (chunking for small-context local models, simplified prompts for weaker ones); honest UI messaging when a chosen model is below the quality bar.
    - **Golden-transcript eval suite:** fixed test transcripts (discovery call, demo, negotiation, messy multi-speaker) with assertions on what a good follow-up contains, runnable against every supported provider and the local-model path. This encodes what "good" looks like for a sales follow-up — domain specialization as software.
    - **Voice profile stays model-independent:** the learned style guide is injected identically regardless of provider, so switching models changes fluency, not identity.
    - The approval step remains the backstop: the bar is "consistently good enough that approval is a tap," not perfection.

52. **Calendar awareness: auto-fill follow-up recipients and context**
    Match an ingested transcript (item 51) to the call's calendar event so the follow-up is pre-addressed and context-enriched.
    *As Marcus, I want the follow-up pre-addressed to everyone on the meeting invite, so that I never copy email addresses by hand.*
    - Read-only access to the macOS Calendar via **EventKit** (local, no OAuth — any account the user's Calendar app syncs, including Google/M365, comes for free).
    - A transcript is matched to an event by time proximity (file timestamp / ingestion time vs. the event window); ambiguous matches are resolved by asking the user, never guessed silently.
    - Attendee emails pre-fill To/Cc (external attendees To, same-domain colleagues Cc — configurable), fully editable before approval.
    - Event title, attendee names/companies, and description enrich the drafting prompt.
    - Degrades gracefully: no matching event → the item 51 flow proceeds with empty recipients.

62. **Cross-call deal memory (local) — continuity across follow-ups**
    Inspired by the momentum.io teardown (their "Deep Research" analyzes deal data across conversations — cloud-side, org-facing); ours is the local-first, rep-facing translation. Past transcripts and sent follow-ups already live on the user's machine — use them, so the third call with a prospect drafts like a third call, not a first.
    *As Marcus, I want the follow-up to a repeat call to reference what we agreed last time and carry forward unfinished action items, so that my emails read like a relationship, not a transaction.*
    - Ingested transcripts and their sent follow-ups are retained locally (bounded, user-clearable) and matched to a contact/deal by recipient email.
    - When a new transcript matches a prior contact, the drafting prompt receives a compact brief of the last call's agreed next steps and the sent follow-up.
    - Open action items from prior follow-ups that the new transcript doesn't resolve are surfaced ("still open from last time") for the user to keep or drop in review.
    - Everything stays on-device; the brief goes to the LLM only as part of the normal drafting call. No new server anything.
    - Foundation for a future pre-call brief (item 63).

63. **Pre-call brief (local)**
    The other half of item 62's memory: before a calendar-matched call (item 52), surface a one-glance brief — who, last call's outcomes, open action items, the last follow-up sent. Granola and momentum.io both validate the feature; ours is assembled entirely on-device.
    *As Marcus, I want a 30-second refresher before the call starts, so that I walk in remembering what we promised.*
    - A notification or menu-bar surface shortly before a calendar event whose attendees match a known contact (items 52 + 62).
    - Brief contains prior-call summary, open action items, and the last sent follow-up; nothing is fetched from any cloud.
    - Silent for first-time meetings or when no local history matches.

60. **Security-scoped bookmark for the watched transcript folder (if sandboxing lands)**
    The app is currently not sandboxed, so the item 51 watched folder works from a plain stored path. If the App Sandbox is enabled at distribution time (an item 11 decision), a stored path is no longer enough — the user's folder choice must persist as a security-scoped bookmark or watching silently breaks on relaunch. Flagged during the item 51 build (see `docs/post-call-followups.md`).
    *As Marcus, I want the watched folder to keep working across app updates and relaunches, so that auto-drafting doesn't silently die if the app hardens its sandbox.*
    - Decide at item 11 release time whether the distributed app enables the App Sandbox; record the decision here.
    - If sandboxed: the folder picker persists a security-scoped bookmark; launch resolves it and calls `startAccessingSecurityScopedResource`; a stale bookmark is detected and surfaced through the existing `transcriptFolderError` state ("choose the folder again in Settings").
    - If not sandboxed: close this item by documenting that decision.

## Low Priority

31. **Outlook / Microsoft 365 support**
    Add an Outlook/M365 provider behind the email-provider abstraction.
    *As an Outlook user, I want to connect my M365 mailbox, so that I can use sentwise without Gmail.*
    - Graph API + OAuth provider implementing the shared email-provider interface.
    - Feature parity with Gmail for read/draft/send.

32. **IMAP/SMTP connection (app password)** — *PRIMARY connection path*
    IMAP + Google app password is the primary way users connect (decided 2026-07-03, superseding OAuth item 3). Provider-agnostic, works for Gmail/Outlook/any IMAP host. Built on SwiftNIO (`swift-nio-imap`) in `Packages/SentwiseMail`.
    *As anyone, I want to connect by pasting my email + an app password, so that I skip Google Cloud setup entirely.*
    - ✅ `MailProvider` protocol + `IMAPMailProvider` (TLS connect + IMAP LOGIN/LOGOUT); "Test Connection" wired into Settings; app password stored in Keychain. **Live-verified against real Gmail 2026-07-04.**
    - ✅ Recent-message fetch (LOGIN → SELECT → FETCH UID+ENVELOPE → LOGOUT), newest first; sender/subject/date parsed; "Preview inbox" action in Settings. State machine + envelope parsing covered by EmbeddedChannel tests.
    - ✅ Body-text fetch (`UID FETCH BODY.PEEK[TEXT]`, streaming assembly over NIO, no `\Seen` flag set) + `MailBodyText` readable-text reduction (multipart, quoted-printable/base64, HTML-strip fallback). "View body" preview sheet in Settings. Covered by EmbeddedChannel + pure unit tests.
    - ✅ **Fetch + body live-verified** against real Gmail incl. `[Gmail]/Sent Mail` (2026-07-19).
   - ✅ **SMTP send live-verified against real Gmail (2026-08-13, branch `send-path-verify`):** the credential-gated `GmailLiveSendTests` dispatched a self-addressed reply through the production auto-send path and asserted delivery, addressing, threading, and the Sent Mail copy (see item 9 in `resolved.md`).
   - ⬜ **Remaining:** efficient `BODYSTRUCTURE`-guided fetch of just the `text/plain` part (avoids downloading attachments; also fixes single-part transfer-encoding decoding); handle missing provider-native features (push, labels) gracefully.

33. **Multiple-account support**
    Watch more than one mailbox.
    *As Priya, I want to connect multiple mailboxes, so that work and personal email are both handled.*
    - Multiple accounts, each with its own voice profile and settings.
    - Clear per-account attribution in notifications and history.

34. **Per-recipient / per-context voice profiles**
    Distinct voice tuning per relationship.
    *As Priya, I want different tone for clients vs teammates, so that drafts fit each relationship.*
    - Optional per-recipient or per-context voice variants.
    - Falls back to the base profile when no variant applies.

35. **Opt-in anonymous telemetry**
    Privacy-respecting, off-by-default metrics.
    *As a maintainer, I want opt-in usage signal, so that I can prioritize development without compromising privacy.*
    - Off by default, fully disclosed, opt-in only.
    - No email content ever included.

37. **Gmail push (watch API) real-time option**
    True real-time inbox updates as an upgrade over polling.
    *As Priya, I want near-instant drafts when mail arrives, so that I'm not waiting on a poll interval.*
    - Optional Gmail `watch` (Pub/Sub) push path as an alternative to the item 5 poller.
    - Documented infrastructure tradeoffs vs the local-first polling default.
    - Falls back to polling when push isn't available.

38. **CI hardening (required checks + caching)**
    Follow-ups from the initial CI pipeline (item 15).
    *As a maintainer, I want CI enforced and fast, so that broken code can't merge and runs stay cheap.*
    - Enable branch protection on `main` requiring the CI check to pass before merge.
    - Cache SwiftPM/Xcode build dependencies to speed up runs.

53. **Platform transcript integrations (Zoom first, Teams later)**
    Pull call transcripts automatically from the user's own meeting-platform account — no bot joins the call, nothing transits an sentwise server.
    *As Marcus, whose org records to Zoom cloud, I want new call transcripts picked up automatically, so that I never export a file by hand.*
    - **Zoom first:** poll the cloud-recordings API with the user's own credentials for newly completed transcripts. **Polling, not webhooks** — a local-first app has no public URL; a "dumb relay" push function (Cloudflare Worker/Lambda that forwards only a "new recording exists" ping, never the transcript) is a natural later upgrade now that the managed-inference service (item 56) means a server exists anyway.
    - Transcripts are fetched directly from the platform to the Mac and feed the item 51 `TranscriptSource` pipeline.
    - **Teams (Microsoft Graph) is a follow-on**; its tenant-admin-consent requirement must be documented honestly — same lesson as the parked BYO-OAuth path (item 3). Requires-IT-approval is expected for many orgs.
    - Per-platform setup friction (cloud recording enabled, plan requirements, credentials) documented; when the API path isn't available, degrade cleanly to item 51's file/folder ingestion.

54. **Native call capture + on-device transcription**
    Capture call audio locally and transcribe on-device. The biggest lift in the pivot; explicitly gated on item 51 proving demand.
    > **Competitive context (2026-08-12):** bot-free capture is being commoditized — Fathom now ships a bot-free desktop app, and Granola has been bot-free from day one (both still process calls in their cloud). The differentiation this item must protect is **on-device transcription** — audio and transcript never leave the Mac — not bot-free capture per se.
    *As Marcus, I want calls transcribed on my Mac with no bot joining and no audio leaving the machine, so that prospects never see "Notetaker has joined the meeting."*
    - System-audio + microphone capture via Core Audio process taps / ScreenCaptureKit, working across Zoom/Meet/Teams whether in a desktop app or a browser.
    - **On-device transcription** (Apple Speech / whisper.cpp class); speaker diarization is *not* required for v1 — a next-steps email doesn't need per-speaker attribution.
    - Call start/end detection (mic-in-use heuristics plus a manual control), with call-end automatically triggering the item 51 workflow.
    - A clearly visible "transcribing" indicator whenever capture is active, and a documented consent/disclosure story (two-party-consent jurisdictions) **before** this ships.
    - **Phased plan (added 2026-08-20):**
      - **54a — Manual capture MVP.** Menu-bar "Start Call Capture" / "Stop & Draft Follow-up". Mic via `AVAudioEngine`; system audio via a Core Audio **process tap** (`CATapDescription` / `AudioHardwareCreateProcessTap`, macOS 14.2+ → bump `MACOSX_DEPLOYMENT_TARGET` 14.0 → 14.2), which captures whatever the user hears regardless of Zoom/Meet/Teams in an app or a browser. Streams mixed to 16 kHz mono in a temp file inside the app's container and **securely deleted once transcription completes** — audio is never retained. Capturing mic and system audio as separate streams gives "You:" / "Them:" attribution for free, without diarization. Always-visible indicator (status-item icon swap + menu line). Output is an `IngestedTranscript` via a new `CaptureTranscriptSource` into the item 51 pipeline — the composer opens pre-filled; nothing is auto-sent.
      - **54b — Transcription engine spike (decide before building 54a's transcription step).** Compare on one real ~30-minute sales-call recording: Apple `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+, on-device, long-form), `SFSpeechRecognizer` with `requiresOnDeviceRecognition` (macOS 14+, but short-request limits force chunking and quality is weaker), and bundled **whisper.cpp** (Metal; +150 MB–1.5 GB app size depending on model). Criteria: word-error rate on call audio, time-to-transcript, app size, minimum macOS. Expected outcome: `SpeechAnalyzer` when available with whisper.cpp as the macOS 14–15 fallback — or require macOS 26 for capture and say so on the landing page.
      - **54c — Automatic call detection.** Trigger = default input device in use (`kAudioDevicePropertyDeviceIsRunningSomewhere`) **and** a known conferencing process running (zoom.us, Microsoft Teams, Webex, Slack huddle, or a browser whose front tab title matches Meet/Teams). First version **asks** ("Looks like a call started — capture it?") rather than starting silently; call end = mic released for N seconds → stop → item 51 workflow. Per-app allow/ignore list in Settings.
      - **54d — Consent & disclosure (before any external release of 54c).** Just-in-time TCC explanations (Microphone; audio-capture/Screen Recording as the tap requires), a first-use consent sheet covering two-party-consent jurisdictions and recommending the user disclose recording, and a `docs/` page. Ships alongside 54a for dogfood, hardened before release.
    - **Gate (revised 2026-08-20):** the original "wait for paying users" gate is waived for **owner dogfooding**; build order across items 30, 54, and 70 is decided after planning. 54b → 54a is the first slice; 54c/54d precede any release.

55. **CRM logging (HubSpot first, Salesforce later) — Team-tier differentiator**
    After a follow-up is approved, log the call summary and sent email to the CRM against the right contact/deal.
    *As Marcus's sales manager, I want call activity landing in the CRM without nagging reps, so that pipeline data reflects reality.*
    - After approval, optionally log the call summary + follow-up email to **HubSpot** (first; friendlier API/auth for individuals) or Salesforce, matched to contact/deal by attendee email.
    - Uses the user's own CRM credentials; calls go directly Mac → CRM, keeping the local-first promise.
    - Off by default, per-call opt-out; failures never block the email send itself.
    - Positioned as the **Team-tier** feature in the item 56 pricing model — the follow-up email sells to the rep, CRM hygiene sells to the manager who holds budget.
