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

72. **Legal, policy, and support foundations for a paid launch** — *⚠️ on hold (owner decision 2026-08-30): the whole legal/policy/site bundle — including the previously "ready" slices (Security page, support@/security@, in-app links) — waits for the item 57 discussion; don't draft or build any of it before then. Prereqs that can still run on their own clocks when the owner chooses: Anthropic ZDR terms in writing (needed for the zero-retention claim, item 56) and the Paddle vendor application (needs the hosted policies, so it follows 57).*
    > **Dependency check (2026-08-28):** several pieces can't be finalized now — ToS **fair-use caps** depend on item 56b (metering, unbuilt); **refund/trial final terms + "reviewed against MoR requirements"** depend on Paddle setup + the item 57 pricing discussion; the Privacy Policy's **zero-retention claim** needs Anthropic's ZDR terms confirmed **in writing** first (per item 56). The self-contained slices that *are* ready — Security page + `security@` disclosure + credentials explainer, a Support (`support@`) doc, and in-app Legal & Support links — can be pulled forward independently; the Privacy Policy and ToS wait on the above. Legal text needs owner (and ideally legal) review before this closes.
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
    App side delivered on branch `account-pane` (Subscription tab in the native Settings window). Checkout + Manage billing wired on branch `paddle-checkout` (56c app half).
    - ✅ Sign in / sign out; shows account email, plan (Trial / Starter / Pro / Unlimited), trial days remaining or renewal date. (`account-pane`, tiers on `paddle-checkout`)
    - ✅ Usage this period vs. allowance (from item 56b) with the "switch to your own key for unlimited" link into the item 59 power path. (`account-pane`)
    - ✅ **App-side "Manage billing"** opens the Paddle customer portal when `subscription.manageBillingUrl` is a valid `http(s)` URL, and a **Subscribe** CTA opens Paddle checkout; enabled/disabled by URL presence (live or cached), with a Subscribe entry for non-active-paid states. (`paddle-checkout`, 56c app half) — the Worker still needs to *provide* `manageBillingUrl` via the Paddle webhook (56c worker half).
    - ✅ **Delete account** (server-side data removal incl. usage counters via `DELETE /v1/me`; local data untouched — separate reset action); DELETE-gated confirmation sheet. (`account-pane`)
    - ✅ Lives as a toolbar tab in the native Settings window (item 65); Prowl hunt-safe AX identifiers, stubbed status + no-op delete in hunt mode. (`account-pane`)

74. **Launch readiness: clean-Mac verification, security pass, and the 1.0 release**
    The last item to close before inviting the public. Every release so far was tested on the maintainer's own configured Mac; a stranger's experience — Gatekeeper, fresh Keychain, no prior Application Support, TCC prompts — has never been observed.
    *As the maintainer, I want proof that a first-time user on a clean Mac gets from download to first draft without help, so that launch day isn't debugging day.*
    - **Clean-machine run** (fresh macOS user account or VM): DMG install via browser download (Gatekeeper/notarization path), `brew install --cask` path, first-run onboarding with sign-in/trial + Gmail app password, voice learn, first inbox draft, first transcript follow-up, approve via notification, Sparkle update from the previous version. Every friction point logged as a backlog item.
    - **Security pass** via `/security-review` on the app and the service repo: token handling, proxy auth, Keychain usage, log redaction, dependency audit.
    - **Release hygiene:** version **1.0.0** via `/release-prep`; CHANGELOG written for humans; cask and appcast verified from a machine that isn't the maintainer's; GitHub release notes link the quickstart (item 71).
    - **Feedback inbox live:** the `feedback@sentwise.ai` address wired into the app's "Report a Problem" (item 36) must be a real, monitored mailbox before launch (Google Workspace setup) — the app ships the address regardless, but a stranger's feedback must actually reach the maintainer.
    - Launch checklist recorded in `docs/` and ticked; this item closes when the public link goes out.

89. **Worker OAuth landing routes missing — Google & OpenRouter one-click sign-in dead-end at a 404** — *discovered 2026-09-07 during 56c live-verify*
    The app's one-click sign-in paths (Google via Clerk OAuth, OpenRouter PKCE — both from item 59) send the browser back to Worker landing URLs — `GET /auth/callback?rotating_token_nonce=…` and `GET /openrouter/callback?code=…` — that forward to the `sentwise://` custom scheme. Those routes were **never implemented in `sentwise-service`**: `index.ts` has no `/auth/callback` or `/openrouter/callback` handler, so the browser lands on the Worker's catch-all `404 {"error":{"type":"not_found","message":"Not found."}}`. Item 59's docs (`docs/managed-inference.md`) describe the `/auth/callback` landing page as if it exists; it does not. Confirmed by live probe of the deployed Worker (2026-09-07) and by the owner hitting the raw JSON 404 when clicking **Continue with Google** on the Subscription tab. **Email-code sign-in is unaffected and is the working path.**
    *As a first-time user, I want the Google/OpenRouter sign-in buttons the app shows me to actually complete, so that I don't get dumped on a raw JSON error page during onboarding.*
    - Implement `GET /auth/callback` in the Worker: a tiny HTML landing page ("You're signed in — you can close this tab") that forwards only the allow-listed `rotating_token_nonce` to `sentwise://oauth-callback?rotating_token_nonce=…`; stores/logs nothing (privacy-clean, like the rest of the Worker).
    - Implement `GET /openrouter/callback` likewise, forwarding only `code` to `sentwise://openrouter-callback?code=…`.
    - Add both paths to the Worker's known-route allowlist so they don't fall through to the 404, and cover them with tests (route exists, forwards only the allow-listed param, rejects/ignores extras).
    - Clerk dashboard prerequisites (from item 59, still owner-side): enable the Google social connection and add `https://sentwise-inference.sentwise-service.workers.dev/auth/callback` to the redirect allowlist.
    - **First-run guard (app):** until the routes ship, hide or disable **Continue with Google** / OpenRouter one-click (`ManagedSignInControls(showsGoogleOption:)` already exists) rather than presenting a button that renders a raw 404 — a launch-quality trap for item 74.
    - Reconcile `docs/managed-inference.md` with reality once implemented.

90. **In-app plan management (current tier + upgrade/downgrade/cancel) and fix the silently-dead "Manage billing"** — *owner-requested 2026-09-07 after live 56c verification*
    Two linked gaps found right after the first live sandbox subscription. (1) **"Manage billing" silently no-ops:** `canManageBilling` is true for any paid account (`hasManageablePaidSubscription`), so the button is *enabled*, but `openManageBilling()` does `guard let url = manageBillingURL else { return }` and `subscription.manageBillingUrl` is **nil** — the Worker webhook's Paddle `management_urls` fetch is coming back empty — so clicking it does nothing. (2) **No in-app way to see or change tier:** a paying user can't view their current plan against the others or move between them.
    *As a paying user, I want to see my current plan and switch between Starter / Pro / Unlimited — or cancel — from inside Sentwise, so that I can manage my subscription without hitting a button that does nothing.*
    - **Fix the dead button (launch-quality — belongs with item 74):** never present an enabled "Manage billing" that no-ops. Either populate `subscription.manageBillingUrl` reliably (diagnose why the webhook's `management_urls` fetch returns empty in sandbox; the Worker already exposes an on-demand `GET /v1/paddle/manage-billing` → `{managementUrl}` that the **app never calls** — wiring that on-demand fetch is the likely fix), or disable/hide the control with a clear message until a real URL exists.
    - **Show the current plan:** the Billing section displays the three tiers (Starter / Pro / Unlimited) with the active one clearly marked ("Current plan"), each with its price and weekly allowance.
    - **Upgrade / downgrade:** Starter→Pro→Unlimited and back are a Paddle **subscription update with proration** via a new authenticated Worker endpoint (Paddle subscription-update API) — **not** a second recurring checkout. Confirm the change, then reconcile `/v1/me` so the pane reflects the new tier. The webhook already updates `privateMetadata.subscription` on `subscription.updated`.
    - **Cancel:** offer cancellation (Paddle portal or a Worker endpoint), reflecting the `canceled`/`lapsed` states the pane already handles.
    - Prowl hunt-safe (stubbed, zero network); AX ids on the new controls; billing-only copy (no privacy/retention claims).
    - Tests: dead-button fix (no enabled no-op), tier display per plan, the upgrade/downgrade proration flow, cancel, and `/v1/me` reconciliation.
    - This is the deferred **Upgrade/Downgrade** follow-up to 56c. Depends on the Worker gaining a subscription-update (and cancel) endpoint.
    - ✅ **Built — pending live verification** *(2026-09-08; app branch `plan-management`, worker branch `subscription-management`)*: **Worker** — new Clerk-authed `POST /v1/paddle/change-plan` (PATCHes the Paddle subscription to the target tier with `prorated_immediately`, updates `quota.weeklyDraftLimit`, idempotent with the `subscription.updated` webhook), and confirmed `GET /v1/paddle/manage-billing?action=cancel|<default>` returns a fresh `{managementUrl}`. Root cause of the dead button: the webhook-stored `subscription.manageBillingUrl` is null **by design** (Paddle `management_urls` are temporary, returned only on the live `GET /subscriptions/{id}`), so the on-demand endpoint is the reliable source (336 worker tests green). **App** — dead "Manage billing" fixed (on-demand fetch + inline message, never a silent no-op; `canManageBilling` no longer keyed on the stored URL), a three-tier plan view with the current tier marked, upgrade/downgrade via `change-plan` with a prorated confirm + `/v1/me` reconcile poll, and cancel via the on-demand cancel URL (full suite 1743 tests, 0 failures). **Remaining:** merge both branches, deploy the worker, then a live sandbox round-trip (upgrade → downgrade → cancel). The plan cards show $9/$19/$39 with **monthly** allowance labels from the landing page — the weekly-vs-monthly metering unit stays an open owner decision. Pre-existing flaky test to harden separately (unrelated to this branch): `AppStateBillingTests.testScheduledManagedStatusRefreshRunsWhenFreshnessIsNearExpiry` (a timing race that asserts before an async refresh completes under load).

## Medium Priority

83. **Approval-signal learning loop (accept-as-is / edit / deny → better drafts + smarter filtering)** — *ongoing/strategic; phase 1 is a cheap early slice*
    Treat the user's action on every draft — approved untouched, edited-then-approved, or denied — as durable feedback that (a) improves drafting in the user's voice and (b) tightens what gets drafted at all, so the assistant manages the inbox better the more it's used. Prompted by the owner seeing drafts generated for mail that shouldn't be drafted, and realizing a one-shot-accept vs edit vs deny signal is the raw material for learning the user over time.
    *As Priya/Marcus, I want Sentwise to learn from how I handle its drafts — what I accept as-is, what I rewrite, what I throw away — so that over time it drafts more of what I'd actually send and stops surfacing mail I never reply to.*
    - **Current state (2026-08-28):** the activity log records `draftCreated` / `approvedSent` / `approvedSaved` / `denied` / `skipped`; item 19 captures original-vs-edited body on the draft (`originalBody`/`wasEdited`); reply-worthiness skip *reasons* are stored — but only for watcher auto-skips. **Gaps:** `denied` carries no reason; approve doesn't distinguish one-shot vs edited; the edit delta isn't durably stored or consumed (item 19's capture was groundwork for an unbuilt voice-tuning step, items 20/34, and its only reader today is the stale-draft sweep); nothing studies any of it.
    - ✅ **Phase 1 — capture the signal (cheap, non-destructive, worth doing sooner)** *(done; branch `approval-signal`; see `docs/approval-signal-learning.md`)*: an on-device append-only feedback store (`DraftFeedback.json`, capped at 2000, survives relaunch and flushes synchronously on graceful termination) records one `DraftFeedbackRecord` per terminal action — approved-as-is vs approved-after-edit (from item 19's `wasEdited`) with a pure normalized edit-magnitude metric (`DraftEditMagnitude`, capped character-level Levenshtein ratio with bounded sparse-aware and moved-block-aware fallbacks for unusually large pasted edits), send behavior (sent/saved), provenance (watcher vs manual preview vs "Draft anyway" override vs authored follow-up; item 68 may later refine the watcher bucket), answered-needs-info (item 85's `wasAnswered`), and a SHA-256 draft-identity hash. Records hold codes/numbers/hashes only, except the deny "Other" free text (local-only and Unicode-scalar capped before storage). Capture runs after successful queued, preview-sheet, and legacy generated-draft dispatches, plus the deny flow; manual preview dismissals record an `abandoned` outcome, including when a closed in-flight preview dispatch or regeneration later completes without approval; offline-drain still records once at real dispatch. **The store is the substrate phases 2–4 and items 84/35 read; nothing off-device in this branch.**
      - ✅ **Deny-reason capture (owner decision 2026-08-28)** *(done; branch `approval-signal`)*: hitting **Deny**/**Discard** presents a single-select reason picker before the deny finalizes — presets "Not worth replying" / "Wrong tone" / "Wrong content" / "Handle later" (stable codes `not_worth_replying` / `wrong_tone` / `wrong_content` / `handle_later`) plus **Other** (code `other`), which reveals a MANDATORY free-text field; the deny cannot complete until a reason is chosen and, for Other, non-empty text is entered. Cancel aborts cleanly (draft stays). The activity `denied` event stores the reason *code* and renders the matching label (never the free text); free text stays only in the feedback store, capped before persistence and never logged.
      - ✅ **Friction guard** *(done; branch `approval-signal`)*: the picker pre-selects the last-used reason and a per-session "Don't ask again this session" checkbox reuses it silently for the rest of the app run (still recorded); while a picker is active, additional deny requests are ignored so the prompt target cannot be silently replaced. Prowl: the confirm control (`denyReasonConfirm`) is forbidden like Deny; all picker controls carry AX ids (`denyReasonPicker`, `denyReasonOption-<code>`, `denyReasonOtherField`, `denyReasonConfirm`, `denyReasonCancel`, `denyDontAskAgain`); hunt-mode writes to the in-memory sink (zero disk side effects).
    - **Phase 2 — feedback → reply-worthiness:** learn sender/type patterns the user consistently denies as "not worth replying" and fold them into the gate (suggest, or auto-add to the item 18 blocklist / raise the bar for that sender), directly closing the "drafting things that shouldn't be drafted" gap. Always transparent and reversible.
    - **Phase 3 — feedback → drafting voice:** feed accept/edit deltas into the voice-profile refresh (items 20/34) — rewrites teach tone/content preferences; one-shot accepts reinforce. Wire into the model-consistency eval (item 58) so quality is measured, not assumed.
    - **Phase 4 — surface the loop:** a simple local "how am I doing" view (one-shot-accept rate, edit rate, deny rate over time) so the user (and maintainer) can see it working. *(User-facing half delivered by item 84's Settings → Analytics window — resolved 2026-09-01, branch `usage-insights` — which surfaces these rates, the deny-reason code breakdown, edit magnitude, and the answered-then-approved count on-device; the maintainer-diagnostics angle and any phases 2/3 consumption remain, so phase 4 is not marked done.)*
    - **Privacy (load-bearing) — two distinct layers, do not conflate:**
      - **On-device (default, always):** all signal capture, storage, and per-user learning stay on the Mac — the user's own data improving their own experience, fully consistent with no-storage / no-training; never a shared or trained model, and any inference still rides the normal per-draft call. The owner's own dogfooding reasons live here too and are locally reviewable (activity log / a maintainer view).
      - **Cross-user aggregation (to "revise the draft algorithm as we gain users") is a SEPARATE, opt-in path.** Sending deny reasons off-device to inform product-wide drafting is **telemetry** and must go through item 35's opt-in, disclosed channel — never silent, or it breaks the no-storage/no-training promise.
      - **Mechanism (owner decision 2026-08-28):** a single **opt-in toggle in Settings → Diagnostics** (default OFF; Privacy section is an acceptable alternate home) gates it, with a one-line disclosure of what's shared. When on, send **structured reason *codes* only** (e.g. `not_worth_replying`, `wrong_tone`, `wrong_content`, `handle_later`) plus app/OS metadata — **keep the "Other" free text LOCAL** (or scrub it before send), since free text can contain mail content. Disclosed in-app and in the privacy policy (item 72). This is item 35's channel; build the toggle there.
      - **Surfaced in the Setup Assistant (owner decision 2026-08-28):** to get real adoption, the ask is presented prominently as a step in onboarding (items 2/59) — **not** buried in Settings — with copy explaining why we ask and how it improves the user's drafts over time. It is a **prominent opt-in, NOT pre-enabled / not opt-out**: an explicit choice (e.g. "Help improve Sentwise" **Enable / Not now**) with nothing pre-selected, then mirrored by the Settings → Diagnostics toggle so the user can change their mind. Rationale for not pre-checking: it targets the product's own privacy differentiator, pre-ticked consent is invalid under EU ePrivacy/GDPR (Planet49), and privacy-aware users reflexively opt out of pre-enabled telemetry — a surfaced explicit choice converts better without the trust/legal risk.
    - Ties to items 17/18/19/20/21/34/35/58/66/67/68.

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

86. **Live in-call follow-up drafting ("before you end your call")**
    Draft the follow-up *during* the call from a streaming transcript so it's ready the instant the call ends — the capability that unlocks the aspirational landing-page claim.
    > **Origin (2026-09-02):** the landing-page hero (sentwise-landing-page repo, brand item 2 / page item 3) softened its headline to *"the moment your call ends"* because today's flow drafts from a transcript **after** the call. This item is the graduation path back to the stronger *"before you end your call"* line — do not publish that claim until this ships.
    *As Marcus, I want my follow-up draft already assembling while I'm still on the call, so that it's ready to review and send the moment I hang up.*
    - Builds on item 54 (native call capture + on-device transcription — specifically 54a/54b, ideally 54c) and the item 51 workflow: audio is transcribed **incrementally during the call**, not only at call end.
    - The draft is materially complete by call end; call-end simply finalizes and opens the review/composer flow.
    - Same privacy posture as today: audio and transcript stay on-device; drafting inference leaves only via the managed zero-retention proxy or BYO/local exactly as item 56 — live drafting must not weaken this.
    - The visible "transcribing" indicator (item 54) also conveys a draft is being prepared; **nothing is auto-sent** — deliberate approval in the Review Drafts window is unchanged (item 79).
    - Degrades gracefully: if live drafting isn't available or enabled, fall back to the current post-call draft with no user-facing error.
    - **Marketing tie-in:** when this lands, coordinate the landing-page copy graduation (sentwise-landing-page items 2/3) back to "before you end your call."

87. **Trial-ending reminders (7-day and 1-day)**
    Native notifications that nudge the user before the 14-day trial converts, so the pay prompt at trial end isn't a surprise.
    > **Origin (2026-09-04):** owner decision on the launch billing flow — app-managed 14-day trial (no card up front, item 56a), user prompted to pay when the trial ends. These reminders raise conversion by warning ahead of time.
    *As a trial user, I want a heads-up before my free trial ends, so that I can decide to subscribe (or not) without being caught off guard.*
    - Two native macOS notifications during the trial: **7 days out** and **1 day out** from trial end.
    - Copy states the trial end date and that payment continues the plan; tapping opens the subscribe/account flow (item 56c). Nothing auto-charges — consistent with the no-card trial and the deliberate-approval ethos (item 79).
    - Timing derives from the **server-side trial state** (56a stores trial end in Clerk metadata); each reminder fires once, idempotent across relaunches (reuse 56b's usage-alert idempotence approach).
    - Local product notifications only — no off-device data; distinct from the opt-in telemetry path (item 83).
    - Degrades gracefully if notifications are disabled: the same countdown shows in Settings → AI Provider and the account pane (item 73).

88. **Trial→paid conversion analytics (server-side)**
    Measure how many trials convert and to which tier, for traction proof and pricing/marketing tuning.
    > **Origin (2026-09-04):** owner request alongside the launch billing flow; pricing confirmed as individual tiers **Starter / Pro / Unlimited** (see sentwise-landing-page item 5).
    *As the maintainer, I want to see trial-to-paid conversion by tier, so that I can prove traction and tune pricing and marketing messaging.*
    - Server-side (`sentwise-service` / licensing) metrics: trials started, converted, conversion rate, time-to-convert, and **which tier** (Starter/Pro/Unlimited); cohort by signup week.
    - These are **billing/licensing events the service inherently holds** — not device telemetry — so **no opt-in consent prompt is required** (distinct from item 83's opt-in off-device feedback). No call or draft content is involved.
    - Surfaced to the maintainer via the existing `/admin` surface (alongside 56b's margin dashboard) or an export; feeds marketing ("X% convert, mostly to Pro").
    - Depends on 56c emitting the conversion/subscription event; complements 56b (usage/margin).

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
