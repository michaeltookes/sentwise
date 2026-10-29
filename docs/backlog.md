# Backlog

Prioritized list of planned features, improvements, and technical debt for **sentwise** — a native, local-first macOS assistant that learns your voice from your Sent mail and drafts email on your behalf, then alerts you when a draft is ready so you can review and approve it in the app (item 79). Its **flagship workflow (2026-08-12 pivot)** is the **post-call follow-up**: when a call ends, ingest the transcript and draft the next-steps email in the user's voice. Inbox reply drafting remains, as one workflow among several.

**Product direction (updated 2026-08-12):**
- **Flagship workflow:** transcript in → next-steps follow-up email out, in the user's voice (items 51–55). The existing drafting → approval → send plumbing is reused; transcript acquisition is the new subsystem, phased: file/paste ingestion first (51), calendar awareness (52), platform APIs (53), native no-bot capture last (54).
- **Primary commercial ICP:** Account Executives / salespeople in high-velocity roles (see **Marcus** persona). Priya remains the persona for the inbox-reply workflow.
- **No bot, no storage, no training:** calls are never joined by a bot; audio and (future) capture/transcription stay on-device; call content is never stored on our servers or used as training data. Drafting inference runs through Sentwise's **stateless no-body-logging managed proxy**; the BYO-key / local-model path is parked in the open-core source only. **Competitive note (2026-08-12):** Fathom ships bot-free desktop capture and Granola always has — and cloud notetakers store calls indefinitely and train on (de-identified) customer data per their own policies. The durable differentiators are (a) privacy that's minimized *and* guaranteed by Sentwise — no Sentwise storage, no Sentwise training, and no Sentwise request/response body logging — and (b) the workflow's back half: a **send-ready email in the user's learned voice, sent from their own mailbox**, not a summary stranded in a notetaker app.
- **Non-goals (2026-08-13, from the momentum.io teardown):** manager/exec-facing surfaces — coaching scorecards, team dashboards, CRO briefings, churn signals, call-clip libraries. Momentum.io (now Salesforce) owns that org-facing lane; our value flows to the **individual rep**, and the org benefits only indirectly via CRM logging (item 55). Agents should not drift features toward the manager persona.
- **Monetization (updated 2026-09-23 for the 1.0 launch — supersedes both "no subscription," BYO-key-as-default, and the earlier Individual/Team framing):** subscription with **managed inference bundled** — the user never touches an API key or provider billing. Unit economics support it: a follow-up costs single-digit cents, so ~175 follow-ups/month ≈ $2–8 against a ~$15–20/mo subscription. Open core / paid binary — source stays public, signed auto-updating binaries are licensed; the license is an **account/sign-in** (needed for inference metering anyway). Trial → Starter → Pro → Unlimited; Team remains a reserved future value and Enterprise is explicitly parked. CRM logging is the planned Unlimited-tier differentiator (item 55). **BYO-key / local-model parked (third revision, 2026-09-16 — item 100):** removed from UI and pricing; managed inference is the only shipped path. The parked code remains in the open-core source for self-builders, unsupported.

**v1 design decisions:**
- **Platform:** native macOS menu-bar app (Swift), following the Prompter distribution pattern (DMG + Homebrew cask + Sparkle auto-update). **Affirmed over an Electron rewrite 2026-08-12** — validate on macOS first (the ICP skews Mac); measure Windows demand via a landing-page waitlist (item 57) and revisit Tauri/Electron only if it fills.
- **Approval channel:** native macOS notification first — it alerts that a draft is ready and opens the Review Drafts window (Open / Close only); approval is a deliberate in-app action there (item 79). Slack as a peer channel is item 30 (post-launch).
- **Email provider:** Gmail first. (Outlook/M365 and IMAP/SMTP are future items.)
- **Send behavior:** user-configurable — auto-send on approve *or* save-as-draft.
- **LLM access:** **managed inference only** (bundled, no keys; item 56). *(Superseded 2026-09-16: the BYO-any-provider and local-model paths are parked — removed from UI and pricing, code kept — see item 100.)*
- **Ethos:** local-first, private. Mail data, voice profile, and (future) call audio stay on the user's machine; drafting inference leaves only through Sentwise's stateless managed proxy, which does not log or retain request/response bodies (the sole shipped path since 2026-09-16 — item 100). *(The original "no subscription" and BYO-key-by-default clauses were superseded 2026-08-12 — see Monetization above.)*

**Personas referenced in stories below:**
- **Marcus — Account Executive, high-velocity sales (primary commercial ICP).** Runs 4–8 calls a day on Zoom/Meet/Teams from a company MacBook. Post-call admin — follow-up emails, CRM logging — eats 30+ minutes daily. Expenses $15–20/mo tools without blinking; his manager cares that activity lands in the CRM. May already use a notetaker (Fathom/Granola/Otter) — those transcripts are an ingestion source, not competition.
- **Priya — busy technical professional.** A Solutions Architect. Comfortable installing a signed Mac app and pasting an API key, but does *not* want to run servers or babysit a CLI. Lives in email; wants drafts waiting so she can triage in seconds. Cares about privacy and control.
- **Sam — self-hoster / privacy maximalist (secondary).** Wants everything local, will run a local model, may bring their own Google Cloud credentials. Values openness and "no data leaves my machine."

> **Item format:** every item has a bold title, a one-line summary, a user story (*As a … I want … so that …*), and acceptance criteria. See `CLAUDE.md` for backlog conventions.

## Milestones (pipeline, 2026-10-12)

> Added by the pipeline replan (`docs/plan.md`, test cases in `docs/qa/test-cases.md`). Ordered by distance to the first paid subscription. This section only groups items by milestone; it does not move, renumber, or reword anything below. Items from other repos are filed there by the orchestrator. New items for this plan are 117–124, appended at the end of the file.

| Milestone | Demo | sentwise items | Elsewhere |
|---|---|---|---|
| **M1 v0.2.1 ships** | Sparkle offers 0.2.1 with release notes; status item found by name; Setup Assistant finished plus first follow-up and inbox reply drafts on the clean onboarding path | 113, 116, 117; in flight: 112, 114, 115; QA leg of 74 (§6) | PR #99 (live tests dispatch-only); genkei-ops P1-3 |
| **M2 Funnel is measurable** | `sentwise.ai/changelog` live; pricing cards per tier; `GET /admin/funnel` returns trials, checkouts, paid by tier | 88, 118 | sentwise-landing-page 10, 14; genkei-ops P1-2, 6c-1, 6c-2 |
| **M3 Trial to paid verified** | Fresh account: reminders → "Trial ended" → checkout → "You're on Starter" → cancel shows "Cancels on <date>" | 123 (prerequisite), 124, 119, 87, 92, 120 | sentwise-service: 123 (sandbox deployment), 124 (paused-status fix) |
| **M4 First-run friction cut** | Workspace domain auto-detected; "Continue with Google"; branded verification email | 110, 105, 106, 121, 122 | Clerk dashboard (owner): 74 §1 callback allowlist, 106 templates |
| **M5 Public link and 30-day push** | Public post → site → download → trial on a clean browser; support drill answered within SLA | 74 (close) | genkei-ops P1-1, P1-4, 6c-3/4/5; launch kit; sentwise-landing-page 9 |
| **M6 Sign-in first** | First run shows Google without an app-password field; other IMAP remains under the fallback; Outlook.com connects through Microsoft and recovers correctly | 135 first, 31 second; 136 is item 31's owner prerequisite; 134 gates public 135; 137 feeds that gate | landing-page 16 + sentwise 137 → genkei-ops 31 → sentwise 134 → public 135; landing-page publisher-domain/privacy work supports 136/31 |

### M6 epic — Sign-in first (ranked delivery order)

> This epic groups existing stable IDs without moving or rewriting their canonical items below. Builder order is 135, then 31. Item 136 is owner/vendor enablement in parallel, not a third app-code story. All device cases run on Lucius' Mini; see `docs/qa/test-cases.md` TC-M6-01–TC-M6-11.

1. **Item 135 — Google and other-IMAP sign-in-first** (US-sign-in-first-1 to 4; TC-M6-01, TC-M6-02, TC-M6-03, TC-M6-08, TC-M6-09)
   - **US-1 — first-run Google path**
     - T135-1 Flag `SENTWISE_SIGN_IN_FIRST` (new `Sentwise/Config/SignInFirst.xcconfig`, empty) -> Info.plist `SentwiseSignInFirst` -> `BuildConfiguration.signInFirst`; `QA.xcconfig` sets `YES`. Hide applies only when the flag is on and `isGoogleSignInAvailable`.
     - T135-2 Email field moves outside the disclosure, shared with the app-password form; Google uses it as `login_hint`.
     - T135-3 Hidden state in `GoogleOrAppPasswordConnect` for onboarding and Settings; disclosure "Other ways to connect", identifier `otherWaysToConnect`; existing identifiers kept.
     - T135-4 Onboarding subtitle per state (copy from the UX review).
   - **US-2 — non-Google IMAP fallback**
     - T135-5 Inline provider hints (no auto-expand), including the Microsoft note until item 31 ships.
   - **US-3 — existing account compatibility**
     - T135-6 `SavedMailAccount.authProvider` with launch back-fill; Settings expands the disclosure for app-password accounts.
   - **US-4 — gated release and regression coverage**
     - T135-7 Release wiring: repository variable `SENTWISE_SIGN_IN_FIRST`, set only by the owner after 134 is done; release-checklist line.
     - T135-8 View-state tests: flag off; flag on with Google; flag on without Google; existing app-password account; Microsoft-domain note.
   - **Done:** QA demonstrates the hidden field, fallback, Google success, existing-account migration and accessibility assets; item 134 is recorded complete before Michael enables the public flag.

2. **Item 31 — Microsoft XOAUTH2, personal accounts first** (US-sign-in-first-5 to 10; TC-M6-04–TC-M6-07, TC-M6-09–TC-M6-11)
   - **US-6 — provider-neutral foundation and personal-account connection**
     - T31-1 ✅ shipped 2026-10-28 (PR 133), see resolved.md
   - **US-9 — mail transport and folder compatibility, before UI**
     - T31-6 `SentwiseMail` SMTP STARTTLS (`SMTPSecurity.startTLS`, refuse AUTH without STARTTLS) and saved-account fields `smtpHost`/`smtpPort`/`smtpSecurity`/`authProvider` (schema 12, additive).
     - T31-8 `MailboxNaming.microsoft` plus IMAP SPECIAL-USE discovery for Microsoft accounts.
   - **US-5 to US-8 — Microsoft configuration, recovery, detection and UI**
     - T31-2 Microsoft configuration: `Sentwise/Config/MicrosoftOAuth.xcconfig` `SENTWISE_MICROSOFT_CLIENT_ID` -> `SentwiseMicrosoftOAuthClientID`; authority `common`, redirect `http://localhost:<port>`, scopes `IMAP.AccessAsUser.All SMTP.Send offline_access openid email`, no client secret; release secret pass-through.
     - T31-3 Error mapping (architecture 4.6): `.adminConsentRequired`, `.reauthenticationRequired` (also Google `invalid_grant`), `.mailboxProtocolDisabled`; admin note; refresh-token rotation persisted.
     - T31-4 Detection: `EmailProviderKind.microsoft` (outlook/hotmail/live/msn and regional domains), Microsoft 365 MX (`*.mail.protection.outlook.com`).
     - T31-5 "Sign in with Microsoft" UI and adoption (address and `tid` from the ID token; personal vs work SMTP host).
     - T31-7 SMTP AUTH-only probe at connect; tokens deleted and account not adopted on failure.
   - **US-9 — live mail proof**
     - T31-9 `MicrosoftOAuthLiveTests` on Lucius' Mini (personal + M365 test mailboxes): refresh, IMAP, probe, send to self, Sent Items and Drafts checks.
   - **US-10 — consent and privacy copy**
     - T31-10 Consent copy block (ui-designer, owner-approved) and the sentwise.ai privacy-policy Microsoft section before the public flag.
   - **Done:** a Genkei-owned Outlook.com fixture signs in without a password, refresh rotation persists, offline cached-token launch works, revoked consent produces one reauthentication state, and the final accessibility/consent checks pass. Work/school support may remain gated as stated in the owner assumption.

3. **Item 136 — owner/vendor prerequisite for item 31** (TC-M6-04 and TC-M6-10 live preconditions; registration evidence is not app-code QA)
   - T136-1 Multi-tenant + personal registration (`AzureADandPersonalMicrosoftAccount`), public client flows on, platform "Mobile and desktop applications", redirect `http://localhost`; delegated permissions Office 365 Exchange Online `IMAP.AccessAsUser.All`, `SMTP.Send`, plus `offline_access`, `openid`, `email`; no client secret.
   - T136-2 Publisher domain sentwise.ai via `/.well-known/microsoft-identity-association.json` on the landing page.
   - T136-3 Microsoft AI Cloud Partner Program ID for Genkei Labs LLC and publisher verification.
   - T136-4 Client ID (a GUID, not secret) stored as repository secret `SENTWISE_MICROSOFT_CLIENT_ID`; never committed.
   - T136-5 Confirm the redirect accepts a random loopback port with `http://localhost`; if not, register `http://127.0.0.1` in the manifest and report to the builder.
   - **Waiting on Michael:** approve the company Entra tenant/partner enrolment and accept its terms; assumption: yes, vendor-ops prepares it.
   - **Waiting on Michael:** approve personal-accounts-first if publisher verification lags; assumption: yes.
   - **Waiting on Michael:** approve one Outlook.com and one Microsoft 365 developer-tenant test mailbox; assumption: yes, no cost, and credentials remain outside the repo.

4. **Public Google gate — existing items 137 → 134; no app build is ranked ahead of item 135**
   - `sentwise-landing-page#16` and item 137 provide the verification assets to `genkei-ops#31`; completed verification/CASA closes item 134; only then may Michael enable item 135 on the public release channel.
   - **Waiting on Michael:** accept the CASA lab cost and final public flag flip; assumption: cost accepted by the 2026-10-28 direction, but the flip requires explicit approval after evidence.

After M6 (ranked, not planned): 53, 52, 104, 70, 30, 54, 55.

---

## High Priority

> Resolved items are recorded in [`resolved.md`](./resolved.md). Item numbers are stable IDs — they are not reused or renumbered when items are completed.

> **Launch plan (owner decision 2026-08-20) — the High tier is ordered for a paid public launch:** 56 (managed inference — top priority) → 59 (sign-in-and-go onboarding, depends on 56a) → 66/67 + 69 (first-hour experience) → 24 (signatures) → 61 (live loop observed) → 71 (README/quickstart) → 73 (account pane) → 72 (legal/policy/support, in parallel with 56c) → 75 (Workspace app-password guidance) → 57 (landing page + checkout, in its own repo) → 74 (clean-Mac verification + 1.0 release, closes last). Slack (30), native capture (54), and the transcript test plan (70) are deliberately **deferred** until after launch feedback.

74. **Launch readiness: clean-Mac verification, security pass, and the 1.0 release**
    The last item to close before inviting the public. Every release so far was tested on the maintainer's own configured Mac; a stranger's experience — Gatekeeper, fresh Keychain, no prior Application Support, TCC prompts — has never been observed.
    *As the maintainer, I want proof that a first-time user on a clean Mac gets from download to first draft without help, so that launch day isn't debugging day.*
    - **Clean-machine run** (fresh macOS user account or VM): DMG install via browser download (Gatekeeper/notarization path), `brew install --cask` path, first-run onboarding with sign-in/trial + Gmail app password, voice learn, first inbox draft, first transcript follow-up, approve via notification, Sparkle update from the previous version. Every friction point logged as a backlog item.
    - ✅ **Security pass — done 2026-09-13** (full-repo audit of app + service; report in `docs/security-pass-2026-09-13.md`). Remediation: items **94** (service) / **95** (app) / **96** (local-data purge) must land pre-launch; accepted/noted findings recorded in the report.
    - **Security-pass launch config (from the report):** flip `ENFORCEMENT_MODE` off soft for trials (with item 94); verify the shipped `SUPublicEDKey` matches the real release keypair and the private key is held offline (A-I3); verify Cloudflare secrets are non-empty (`wrangler secret` TTY gotcha) and `ADMIN_TOKEN` has real entropy.
    - **Release hygiene:** version **1.0.0** via `/release-prep`; CHANGELOG written for humans; cask and appcast verified from a machine that isn't the maintainer's; GitHub release notes link the quickstart (item 71).
    - **Feedback inbox live:** the `feedback@sentwise.ai` address wired into the app's "Report a Problem" (item 36) must be a real, monitored mailbox before launch (Google Workspace setup) — the app ships the address regardless, but a stranger's feedback must actually reach the maintainer.
    - **Production Paddle cutover** (**unblocked 2026-09-12 — Paddle vendor account fully verified**; from item 56): point `PaddleConfig.active` / `PADDLE_API_BASE` at the live token + price ids, and mint the **live API key with the `customer_portal_session.write` permission** — discovered 2026-09-12 (item 91): without it the portal-session create fails silently and billing links regress to the email sign-in page. Also: production Clerk instance needs a real Google OAuth client + its own `/auth/callback` redirect-allowlist entry (item 89), and real per-tier allotment numbers set from 56b measurements. **Tier-matrix alignment (from item 98, 2026-09-16):** live Paddle products/prices must match `docs/tier-matrix.md` exactly (Starter $9 / Pro $19 / Unlimited $39, plan ids `starter`/`pro`/`unlimited`); the quota window-unit mismatch is resolved by the Worker `window-unit-fix` (calendar-month UTC, resets 00:00 UTC on the 1st) and the item 101 app/docs alignment, so no launch cutover action remains for the window unit.
    - Launch checklist recorded in `docs/` and ticked; this item closes when the public link goes out.

105. **Sign-in verify shows a transient error despite succeeding — instrument and pin it down** — *observed by the owner 2026-09-21 during the production-Clerk cutover sign-in*
    Entering the email code and hitting Verify flashed an error on the Subscription pane, yet the account came up signed in moments later with no further action. Code review shows `completeSignIn` is strictly ordered (verify → mint → finalize; any throw leaves the app signed out), so the error almost certainly surfaced *after* a successful sign-in — most likely a transient `/v1/me` status-refresh failure sharing the same message surface (the observation window overlapped a worker deploy). The unified log carries no managed-account error lines, so today the path cannot be diagnosed after the fact.
    *As the maintainer, I want sign-in failures and post-sign-in status failures separately visible in logs and in the UI, so that a transient status blip never reads as "my sign-in failed."*
    - Add redaction-safe error-level `Logger` lines through the managed sign-in path (`completeSignIn` stages, post-finalize status refresh), using `SecretKey.logSafeIdentifier`-style hygiene — no emails/tokens in the unified log.
    - Unit-test fault injection: verify succeeds, first `/v1/me` refresh throws transiently — assert the pane distinguishes "signed in; status refresh failed, retrying" from a sign-in failure (today both hit the same transient message surface).
    - Repro harness reality: Prowl hunts are offline (hunt mode cannot exercise live Clerk), and the production instance has no test mode, so a live GUI repro on Lucius needs production test users + mailbox code retrieval — build only if the instrumented logs don't settle it first.
    - Consider surfacing distinct copy for post-sign-in refresh failures ("Signed in — couldn't load your plan yet, retrying…").
    - **Build note 2026-10-26 (`105-signin-status-instrumentation`):** added redaction-safe `ManagedSignIn` stage logs for verify → mint → finalize and the post-sign-in `/v1/me` refresh; the Subscription pane now keeps the account signed in and shows “Signed in. Couldn't load your plan yet, retrying…” until a retry succeeds. Fault-injection tests cover both that recovery and a true verify-stage failure. Keep this item open for the live Lucius observation in v0.2.3.
    - **2026-10-27:** item 104's live Google sign-in check on the QA Mac (which signed in to the Sentwise account in Settings > AI) produced no `ManagedSignIn` log lines, so the observation folds into the v0.2.3 QA pass; build the live Clerk repro only if those logs do not settle it.

106. **Branded Clerk transactional emails (verification code, security notices)** — *owner request 2026-09-21*
    The sign-in code and other Clerk-sent emails currently use Clerk's default template and sender identity. Brand them as Sentwise before launch — these are among the first emails a new user ever receives from the product.
    *As a new user, I want the verification-code email to look like it comes from Sentwise, so that I trust it and recognize it in my inbox.*
    - Clerk dashboard → Customization → Emails: apply Sentwise branding (owl logo, emerald palette, sender name "Sentwise") to the verification-code template and every other enabled template (sign-in code, password/security notices as applicable).
    - Sender domain: the production instance's Email DNS records (3/3 verified on sentwise.ai, 2026-09-19) enable sending from the sentwise.ai domain — confirm the from-address reads as Sentwise (e.g. `noreply@clerkmail.sentwise.ai` or the configured equivalent), not clerk.dev.
    - Send-test each customized template to a real inbox; check rendering in Gmail (light + dark) and Apple Mail, and confirm SPF/DKIM/DMARC pass on the received message.
    - Mostly dashboard work (owner) with agent-drafted template HTML/copy; no app code expected.

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

30. **Slack approval channel** — *spec expanded 2026-08-20; deferred to post-launch (Medium) by the 2026-08-20 launch decision; tier placement decided by the item 98 matrix (2026-09-16 direction: integrations are paid-tier differentiators)*
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

22. **Cost & rate guardrails for cloud LLMs** — *PARKED (2026-09-16, item 100): only relevant if BYO-key/local drafting is revived*
    > **Parked 2026-09-16:** BYO-key and local-model providers were removed from the UI and pricing (item 100), so there is no user-supplied cloud key to guard. The managed tier's metering and fair-use enforcement are server-side (items 56/56b). This item — per-run/per-day cost caps for a user's own cloud key — is only relevant if the parked BYO path is revived.
    Prevent surprise bills.
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
    Engineering consistency for the managed drafting path. *(Scope trimmed 2026-09-16 — item 100: BYO-key/local providers are parked, so this harness now covers only the managed models we curate — one or two chosen models plus safe swaps of the managed default as providers evolve. It no longer needs to govern a BYO/local escape hatch or signal quality on weaker user-brought models.)* **Sequenced after item 51's first working version** — build 51 against the managed default, then grow the harness from the variance actually observed, not speculation.
    *As Marcus, I want the follow-up to be reliably good on the managed default, so that approval is a tap, not a rewrite session.*
    - **Staged pipeline, not one big prompt:** extract action items/decisions into a structured intermediate (JSON) → build recap → render the email in the user's voice; defined input/output contracts per stage so model variance is contained, not compounded.
    - **Deterministic post-generation validation** (code, not the model): structure valid, action items present, length in bounds, no invented recipients, signature policy respected. Failure → retry with feedback, or a visible low-confidence signal in the approval UI.
    - **Per-managed-model capability adaptation:** context-window size and structured-output/tool-calling support detected per curated managed model, so a safe swap of the managed default doesn't silently regress quality.
    - **Golden-transcript eval suite:** fixed test transcripts (discovery call, demo, negotiation, messy multi-speaker) with assertions on what a good follow-up contains, runnable against each curated managed model. This encodes what "good" looks like for a sales follow-up — domain specialization as software.
    - **Voice profile stays model-independent:** the learned style guide is injected identically across managed models, so a model swap changes fluency, not identity.
    - The approval step remains the backstop: the bar is "consistently good enough that approval is a tap," not perfection.

52. **Calendar awareness: auto-fill follow-up recipients and context** — *tier-gated: Pro and above (owner direction 2026-09-17, `docs/tier-matrix.md`)*
    Match an ingested transcript (item 51) to the call's calendar event so the follow-up is pre-addressed and context-enriched.
    *As Marcus, I want the follow-up pre-addressed to everyone on the meeting invite, so that I never copy email addresses by hand.*
    - Read-only access to the macOS Calendar via **EventKit** (local, no OAuth — any account the user's Calendar app syncs, including Google/M365, comes for free).
    - A transcript is matched to an event by time proximity (file timestamp / ingestion time vs. the event window); ambiguous matches are resolved by asking the user, never guessed silently.
    - Attendee emails pre-fill To/Cc (external attendees To, same-domain colleagues Cc — configurable), fully editable before approval.
    - Event title, attendee names/companies, and description enrich the drafting prompt.
    - **Unified agenda view (owner direction 2026-09-17):** a lightweight read-only "today/upcoming calls" surface showing events **merged across every account the user's macOS Calendar syncs** (Google + Outlook + iCloud in one list — EventKit's unified store provides the merge for free; no cloud calendar APIs, no aggregator services like Nylas/Cronofy, no write-back/sync). This is the user-facing "one calendar" — scoped to awareness, never consolidation/sync between providers.
    - Degrades gracefully: no calendar permission or no matching event → the item 51 flow proceeds with empty recipients.

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
    - Same privacy posture as today: audio and transcript stay on-device; drafting inference leaves only via Sentwise's managed no-body-logging proxy or the parked BYO/local mechanics exactly as item 56 — live drafting must not weaken this.
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
    - **QA population kept separate (pipeline replan 2026-10-12):** every funnel datapoint is tagged at write time with a population, `qa` or `live`. An event is `qa` when the account's email domain is in the Worker var `QA_EMAIL_DOMAINS` (item 119's list, initially `prowlqa.dev`) The sandbox deployment (item 123) writes to its own Analytics Engine dataset, so sandbox events never reach the production funnel at all. The tag is stored as an Analytics Engine blob, never the email. `GET /admin/funnel`'s top-level counters (`trialsStarted`, `checkoutsOpened.{starter,pro,unlimited}`, `subscriptionsActivated.{starter,pro,unlimited}`, `subscriptionsCanceled`, `trialToPaidRate`) count the `live` population only. A `qa` object carries the same nine fields for the `qa` population, so each population's rate has a numerator and a denominator from that population alone: QA trial starts never inflate the live denominator, and QA purchases never inflate the live numerator. Vitest: a QA-domain trial start and a QA-domain activation each increment only `qa.*`. **`subscriptionsCanceled` counts effective cancellations only:** one per `subscription.canceled` webhook, dated when Paddle sends it. A cancellation scheduled for the period end (`subscription.updated` with `scheduled_change.action: "cancel"`, item 92) is not counted until `subscription.canceled` arrives at its effective date, matching the webhook's existing mapping, where only `subscription.canceled` produces a canceled status; a scheduled cancel that is later undone is therefore never counted. Vitest: a `subscription.updated` carrying a scheduled cancel leaves `subscriptionsCanceled` unchanged, and the later `subscription.canceled` increments it once.
    - **Cohorts and time-to-convert (plan follow-up 6h, 2026-10-13):** the cohort-by-signup-week and time-to-convert metrics above ship in M2 with the funnel, not later. `GET /admin/funnel` returns `cohorts[]` for the live population and `qa.cohorts[]` for the QA population: one element per signup week (ISO week, Monday UTC, of the account's trial start) overlapping the requested range, ordered by week, each `{ weekStart, trialsStarted, converted, convertedByTier: {starter, pro, unlimited}, medianDaysToConvert }`, where `converted` counts that cohort's first paid activations up to the range end, `convertedByTier` sums to `converted`, and `medianDaysToConvert` is the median of whole days from trial start to first activation (`null` when nothing converted). The activation datapoint records the account's trial start date (from its Clerk metadata) so cohort and days are computed without a join; comp grants (item 111) are not conversions. Vitest: a trial started in week W and activated on Pro 3 days later yields cohort W with `trialsStarted` 1, `converted` 1, `convertedByTier.pro` 1, `medianDaysToConvert` 3, in the matching population only. **Verified by:** TC-M2-06, TC-M2-08, TC-M3-05, TC-M3-09.

92. **Surface scheduled cancellation ("Cancels on <date>") in the Subscription pane** — *discovered 2026-09-12 during the items 90/91 cancel live-verify*
    Canceling from the Paddle portal defaults to **cancel at end of billing period**: Paddle fires `subscription.updated` with `status` still `active` plus `scheduled_change: {action: "cancel", effective_at: …}`. The worker's webhook maps only `status` and ignores `scheduled_change`, so `/v1/me` reports a plain active subscription and the pane shows nothing about the pending cancellation until the period actually ends (when `subscription.canceled` fires and the existing canceled-state handling kicks in). Observed live: owner canceled in the portal and the app kept showing the active Pro plan with no hint the cancel had registered.
    *As a paying user who cancels, I want the app to say my plan ends on \<date\> the moment I cancel, so that I trust the cancellation took effect and know how long I keep access.*
    - Worker: parse `scheduled_change` (at least `action: "cancel"` + `effective_at`) from subscription webhook events and store it in `privateMetadata.subscription`; clear it when a later event carries no scheduled change (cancellation undone in the portal). Explicitly decide/ignore `pause`/`resume` scheduled actions.
    - `/v1/me` exposes the scheduled cancellation (e.g. `subscription.cancelsAt`).
    - App: Subscription pane shows "Cancels on \<date\>" on the current plan (and suppresses upgrade prompts as appropriate); state clears if the user reverses the cancellation. Prowl hunt-safe; AX ids preserved.
    - Tests: webhook parse/store/clear, `/v1/me` exposure, pane rendering for scheduled-cancel and reversal.
    - Live-verify rides the existing sandbox subscription (a cancel is already scheduled for 2026-10-07): once built, the pane should show it without a new purchase.

114. **Sparkle update dialog shows no release notes** — *found 2026-10-08 by the Lucius install-path QA run (0.1.2 → 0.2.0 update)*
    The update prompt ("Sentwise 0.2.0 is now available—you have 0.1.2") renders with an empty release-notes area: the appcast item carries no description or `releaseNotesLink`, even though every release has a human-written CHANGELOG section. Users deciding whether to update see a version number and nothing else.
    *As a user prompted to update, I want to see what changed, so that I can update confidently instead of clicking through a blank dialog.*
    - ~~Release pipeline (release.sh / `generate_appcast`): embed the release's CHANGELOG section (or a `releaseNotesLink` to the GitHub release) in each appcast item.~~ **Done 2026-10-11 (branch `appcast-release-notes`):** `changelog-to-html.sh` renders the version's CHANGELOG section to an HTML fragment (fails if missing/empty); `write-appcast.sh` places it next to the DMG and runs Sparkle 2.9.5 `generate_appcast --embed-release-notes`, then fails unless the item's `<description>` is non-empty; `release.sh` pre-flights the section before archiving. Fixture test: `Distribution/scripts/tests/test-release-notes.sh`. Documented in `docs/releasing.md` / `docs/ci-release.md`.
    - **Open:** verify on the next release that the Sparkle dialog on a previous-version install renders the notes (now a step in the release docs). Resolve the item once observed.
    - No app code change expected — this is appcast generation.

125. **"How did you hear about Sentwise?" at first sign-in (optional, skippable)** — *(post-launch, Medium; from the icp-finder intake 2026-10-14, icp-finder item 27 / US-poc-8)*
    One optional, skippable question after a new user's first sign-in so the founder can see which channel brought them; not run-blocking (the dogfood run is attributed by tracking links plus founder matching), and Michael wants it only once Sentwise is on several platforms with call-to-action pages.
    *As a new user, I want to answer one optional question about how I found Sentwise, or skip it, so that the trial starts either way and nothing about my mail is attached to my answer.*
    - Choices match the icp-finder activity-log `channel` values (reddit, indie_hackers, slack, discord, linkedin, x, email, hn, build_in_public, founder_network) plus "other"; skipping leaves the answer empty and the trial proceeds unchanged.
    - Added 2026-10-16 (email-signature-generator brief `docs/requirements/sentwise-distribution.md`, AC-SD-4.4): the choices also include `signature_generator`, label "Email signature generator", so visitors who came from the free signature generator's house promotion (links tagged `utm_source=email-signature-generator`) can be counted. The item itself stays deferred as Michael set it on 2026-10-14.
    - Only the chosen value is stored against the account; no mail, transcript or draft content goes with it; the founder sees per-channel aggregate counts only; the privacy copy says what is stored.
    - Acceptance: given a first sign-in, one optional question appears and can be skipped; given a skip, the trial starts and the answer is empty; given an answer, it appears in an aggregate count with no account-identifying data.

126. **Transcript-source guidance for new users (Zoom, Granola, Fathom)** — *(pre-launch, Medium; run-blocking for the icp-finder dogfood run, its plan gate line 2; from the icp-finder intake 2026-10-14, icp-finder item 28 / US-poc-10)*
    Sentwise does not record calls, so a new user at the transcript step needs plain in-app guidance on getting a transcript out of the tools they already use; guidance only, the meeting-platform integrations in item 53 stay a separate post-launch item.
    *As a new user at the transcript step, I want to see how to get a transcript out of Zoom, Granola or Fathom, so that my first follow-up does not stall on "where do I get the file".*
    - A visible in-app link or panel, or a linked support page, with plain steps for Zoom (save transcript / cloud download), Granola and Fathom, and the accepted file types when the user uses none of the three.
    - Acceptance: given a new user at the transcript step, the guidance is visible and covers the three sources in plain steps; given none of the three, it lists the accepted file types; done when the icp-finder gate can cite the screen or page.


127. **Import a signature from the email signature generator (plain text)**: *(post-launch, Medium; filed 2026-10-16 from the email-signature-generator brief `docs/requirements/sentwise-distribution.md`, story US-sentwise-distribution-5; design in that repo's `docs/architecture/sentwise-distribution.md` sections 4.1, 5.2 and 7.4; generator side is its items 30 and 31, behind a build flag until a Sentwise release with this handler is published)*
    The free email signature generator gets an **Add to Sentwise** button that copies the signature to the clipboard and opens `sentwise://signature-import?v=1&source=clipboard`. No signature content is ever in the URL. Sentwise opens an import sheet, reads the clipboard only when the user presses **Paste from clipboard**, previews it, and saves it as the Custom signature (the existing item 24 signature policy) only on **Use this signature**. Phase 1 stores the plain-text version, since all outgoing mail is `text/plain` today (`RFC822Message.swift`).
    *As a Sentwise user who just made a signature in the free generator, I want to send it to Sentwise in one click, so that my drafts end with it without retyping it in Settings.*
    - A `signature-import` case in `SentwiseURLCallback`: accepts `v=1` and `source=clipboard`; an unknown `v` opens the sheet in a "needs a newer Sentwise" state ("This signature link needs a newer version of Sentwise. Choose Check for Updates in the menu bar."); a missing `v` or any other `source` is ignored and logged like the existing callbacks; extra parameters are ignored; ignored entirely in Prowl hunt mode.
    - The sheet never reads the clipboard on open; it reads `public.utf8-plain-text` only on **Paste from clipboard**, shows a preview, and writes nothing until **Use this signature**; **Cancel** leaves the current signature unchanged.
    - Acceptance: given Sentwise running or not running and the link opened from a browser, then Sentwise comes to the front with the sheet and the clipboard is not read until the button press; given a paste of the generator's plain text and **Use this signature**, then Settings shows the signature policy set to Custom with exactly that text and the next draft ends with it once (item 24 dedup holds); given an empty clipboard or one with no text, then the sheet says "Nothing to paste. Copy your signature again and press Paste." and saves nothing; given text over 10,000 characters, then it is refused with a message and nothing is saved; given a hostile page opening the link, then nothing changes unless the user pastes and confirms.
    - Acceptance (cold launch): given Sentwise not running and a fresh install, when the link arrives before launch completes, then onboarding is deferred until the import sheet is dismissed, or the import sheet is raised above onboarding after startup; onboarding never covers the sheet (Codex P2 on PR 117, AppDelegate replays pending URLs before opening onboarding).
    - Privacy copy gains: the imported signature is stored on your Mac and never sent to Sentwise's servers. The URL handler and the sheet carry no telemetry beyond the existing local logs.
    - Estimate: about 2 builder-days (handler, sheet, plain-text read, save, tests, Prowl guardrails, docs). Device case on Lucius' Mini with the generator's spike (generator item 30).

128. **HTML signatures: sanitized storage and multipart/alternative send**: *(post-launch, Medium; depends on 127; filed 2026-10-16 from the same brief, architecture section 7.4 and 13)*
    After 127, a signature imported from the generator keeps its layout, colours and logo: Sentwise stores a sanitized HTML signature next to the plain text and sends `multipart/alternative` mail on both send paths (SMTP send and IMAP `APPEND` to Drafts).
    *As a Sentwise user with a designed signature, I want my sent mail and saved drafts to carry the same signature my mail client shows, so that my emails look the same whichever app I send from.*
    - Settings schema bump with migration; an allowlist sanitizer (tables, inline styles, `https` images only when their origin is the generator's own asset host, with width, height and alt; any other remote image, including a 1×1 tracking pixel, is dropped, because an arbitrary remote image would disclose opens and IP addresses to that host and contradict the local-first privacy statement (Codex P1 on PR 117); the wrapping properties the generator emits for long values, constrained: `word-break` normal, break-word or break-all; `overflow-wrap` normal, break-word or anywhere; `max-width` one non-negative px or % length, no calc(), var() or url(); a declaration outside its constraint is dropped, not rewritten; no scripts, no event handlers, no forms, no `<style>`, no remote CSS); `public.html` read on Paste; a preview in Settings; HTML-aware signature dedup.
    - Acceptance: given the generator's HTML for each of its three templates, then the sent message has a `text/plain` part and a `text/html` part, the HTML matches the sanitized golden file, and Gmail web shows the layout; given HTML with a `<script>` or an `onclick`, then they are stripped before storage; given a send or Drafts save with an HTML signature, then MIME golden files and a live send check on Lucius' Mini pass before release.
    - Acceptance (HTML size bound): given the clipboard carries `public.html` over 64 KB or with more than 2,000 nodes, with any plain-text length, when the sheet opens, then the HTML is neither parsed nor previewed, the sheet says the designed version is too large and offers the plain-text import, and the app stays responsive (Codex P2 on PR 117; the 10,000-character limit in 127 bounds only the plain text).
    - Acceptance (wrapping): given the generator's P4 profile (every field at its maximum length) in each of its three templates, imported through the clipboard hand-off, then the sanitized HTML keeps every `word-break:break-word`, `overflow-wrap:anywhere` and `max-width:600px` declaration the template emitted, and the Settings preview and a sent test message viewed at 600 px show no horizontal overflow, with the long email and website values wrapping inside the signature; given a declaration outside the allowed set (for example `max-width:calc(100%)`, `word-break:keep-all` or `overflow-wrap:url(x)`), then that declaration is dropped and the rest of the signature is kept.
    - Acceptance (remote images): given imported HTML with an `https` image on any host other than the generator's asset host, including a 1×1 pixel, then the stored and the sent HTML contain no reference to that host, and a golden test covers it.
    - Estimate: about 5.5 builder-days. Risk: touches the send path for every user, so it ships only with the MIME golden files and the live check.

## Low Priority

116. **Homebrew cask uses deprecated `depends_on macos:` string-comparison syntax** — *found 2026-10-08 by the Lucius install-path QA run (`brew install --cask` warning)*
    `brew install --cask michaeltookes/tap/sentwise` succeeds but warns that the cask's `depends_on macos:` string-comparison form is deprecated. The cask is regenerated by the CI tap bump on every release, so the fix belongs in the generator template, not a one-off tap edit.
    *As a Homebrew user, I want the cask to install without deprecation warnings, so that the install looks healthy and keeps working when brew removes the deprecated form.*
    - ✅ Update the cask template the release pipeline writes. *(2026-10-12, branch `cask-depends-on-syntax`: `Distribution/sentwise.rb` now uses the bare-symbol form `depends_on macos: :sonoma`, which Homebrew reads as Sonoma or newer and parses without the deprecation warning. Note: `">= :sonoma"` was the deprecated form, not the fix. New CI test `Distribution/scripts/tests/test-cask-template.sh` guards it against drift and against `MACOSX_DEPLOYMENT_TARGET`.)*
    - Confirm the next release's tap bump produces a warning-free `brew install --cask`.
    - One-off: patch the live tap cask to match so current installs stop warning. *(2026-10-12: pushed as `michaeltookes/homebrew-tap` branch `cask-depends-on-syntax`, awaiting merge. The tap's `containerbar` and `prompter` casks have the same deprecated line.)*

31. **Microsoft sign-in (Outlook.com, Hotmail, Microsoft 365)** — *second provider, release after launch; rescoped 2026-10-28 from "Graph API" to IMAP/SMTP with XOAUTH2, same shape as the Gmail path. Brief: `docs/requirements/sign-in-first.md` section 6 (US-sign-in-first-6 to 10); depends on 136; architect questions A1-A9 in that section.*
    Add a Microsoft sign-in provider behind the email-provider abstraction.
    *As an Outlook user, I want to connect my M365 mailbox, so that I can use sentwise without Gmail.*
    - ~~Graph API + OAuth provider implementing the shared email-provider interface.~~ Superseded 2026-10-28: IMAP/SMTP XOAUTH2 (Graph rejected, `docs/architecture/sign-in-first.md` section 9).
    - Feature parity with Gmail for read/draft/send.
    - Technical tasks (architecture `docs/architecture/sign-in-first.md` section 11; build in this order):
      - T31-1 Provider-neutral OAuth refactor (`OAuthProviderConfiguration`, coordinator, token service, store, mail-provider wrapper); Google Keychain prefix stays `gmail`; no behaviour change, all Google tests green. Built on branch `31-t31-1-oauth-provider-neutral`.
      - T31-6 `SentwiseMail` SMTP STARTTLS (`SMTPSecurity.startTLS`, refuse AUTH without STARTTLS) and saved-account fields `smtpHost`/`smtpPort`/`smtpSecurity`/`authProvider` (schema 12, additive).
      - T31-8 `MailboxNaming.microsoft` plus IMAP SPECIAL-USE discovery for Microsoft accounts.
      - T31-2 Microsoft configuration: `Sentwise/Config/MicrosoftOAuth.xcconfig` `SENTWISE_MICROSOFT_CLIENT_ID` -> `SentwiseMicrosoftOAuthClientID`; authority `common`, redirect `http://localhost:<port>`, scopes `IMAP.AccessAsUser.All SMTP.Send offline_access openid email`, no client secret; release secret pass-through.
      - T31-3 Error mapping (architecture 4.6): `.adminConsentRequired`, `.reauthenticationRequired` (also Google `invalid_grant`), `.mailboxProtocolDisabled`; admin note; refresh-token rotation persisted.
      - T31-4 Detection: `EmailProviderKind.microsoft` (outlook/hotmail/live/msn and regional domains), Microsoft 365 MX (`*.mail.protection.outlook.com`).
      - T31-5 "Sign in with Microsoft" UI and adoption (address and `tid` from the ID token; personal vs work SMTP host).
      - T31-7 SMTP AUTH-only probe at connect; tokens deleted and account not adopted on failure.
      - T31-9 `MicrosoftOAuthLiveTests` on Lucius' Mini (personal + M365 test mailboxes): refresh, IMAP, probe, send to self, Sent Items and Drafts checks.
      - T31-10 Consent copy block (ui-designer, owner-approved) and the sentwise.ai privacy-policy Microsoft section before the public flag.

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

53. **Platform transcript integrations (Zoom first, Teams later)** — *tier-gated: Pro and above (owner direction 2026-09-16, item 98 matrix); elevated 2026-09-19: build in parallel with the item 74 cutover, launch-NOT-blocking*
    Pull call transcripts automatically from the user's own meeting-platform account — no bot joins the call, nothing transits an sentwise server.
    *As Marcus, whose org records to Zoom cloud, I want new call transcripts picked up automatically, so that I never export a file by hand.*
    - **Zoom first:** poll the cloud-recordings API with the user's own credentials for newly completed transcripts. **Polling, not webhooks** — a local-first app has no public URL; a "dumb relay" push function (Cloudflare Worker/Lambda that forwards only a "new recording exists" ping, never the transcript) is a natural later upgrade now that the managed-inference service (item 56) means a server exists anyway.
    - Transcripts are fetched directly from the platform to the Mac and feed the item 51 `TranscriptSource` pipeline.
    - **Teams (Microsoft Graph) is a follow-on**; its tenant-admin-consent requirement must be documented honestly — same lesson as the parked BYO-OAuth path (item 3). Requires-IT-approval is expected for many orgs.
    - Per-platform setup friction (cloud recording enabled, plan requirements, credentials) documented; when the API path isn't available, degrade cleanly to item 51's file/folder ingestion.
    - **Owner rationale (2026-09-19):** auto-ingestion removes the 3–5 manual clicks per call that Starter users keep, making the Pro upgrade tangible for the Marcus ICP (5–8 calls/day). It complements item 99 multi-account as the Pro anchor.
    - **Marketplace-review reality (2026-09-19) — the schedule gate is external:** a "Connect Zoom" that works for any Zoom account requires a **published Zoom Marketplace OAuth app**, and Zoom's app review (security questionnaire included) typically takes weeks and can bounce. Unpublished apps only work under the developer's own Zoom account, and asking users to create their own Zoom OAuth app is the exact BYO-credentials friction that killed items 3 and 100 — not an option. RingCentral's marketplace has the same shape. Therefore: **submit the Zoom app for review as early as the integration can demo end-to-end**; the review clock, not the build, is the long pole.
    - **Parallel-track decision (owner, 2026-09-19):** the item 74 production cutover proceeds simultaneously and does NOT wait for this item. If Zoom review clears before the launch checklist closes, 1.0 ships with it; otherwise it ships in a 1.0.x Sparkle update. Per the item 98 display rule, the pricing page and tier cards show the integration only once shipped.
    - **Prerequisites to document for users:** Zoom cloud transcripts require a paid Zoom plan with cloud recording + audio transcript enabled (often an admin setting). Add a support-doc table of "if your tool is X, here's your setup," including which tools can auto-export transcripts to a local folder today — item 51's watched folder already makes that zero-click, and it is the bridge while connectors roll out.

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

55. **CRM logging (HubSpot first, Salesforce later) — Unlimited-tier differentiator** — *tier-gated: Unlimited only (owner direction 2026-09-16, supersedes the earlier Team-tier framing; item 98 matrix)*
    After a follow-up is approved, log the call summary and sent email to the CRM against the right contact/deal.
    *As Marcus's sales manager, I want call activity landing in the CRM without nagging reps, so that pipeline data reflects reality.*
    - After approval, optionally log the call summary + follow-up email to **HubSpot** (first; friendlier API/auth for individuals) or Salesforce, matched to contact/deal by attendee email.
    - Uses the user's own CRM credentials; calls go directly Mac → CRM, keeping the local-first promise.
    - Off by default, per-call opt-out; failures never block the email send itself.
    - Positioned as the **Unlimited-tier** feature in the item 56/98 pricing model — the follow-up email sells to the rep, CRM hygiene sells to the manager who holds budget.

## Pipeline milestone items (2026-10-12)

> New items from the pipeline replan (`docs/plan.md`). Each is tagged with its milestone and its priority tier, and names the test cases that verify it (`docs/qa/test-cases.md`). Items that change `sentwise-service` are tracked here because that repo has no backlog and shared work uses sentwise numbers.

117. **Release v0.2.1** — *(M1, High)*
    Cut the patch release that ships items 112, 114 (appcast release notes), 115, 113, and 116, so the QA Mac and early users get the fixes and the update dialog finally shows notes.
    *As a 0.2.0 user, I want a 0.2.1 update that tells me what changed, so that I update with confidence.*
    - `/release-prep` 0.2.1: CHANGELOG `## [0.2.1]` written for humans (fixes listed by user-visible effect); build number above 5; tag pipeline green; DMG notarized and stapled; appcast item carries the 0.2.1 notes (item 114's generator); cask bumped with a matching sha256 and the item 116 syntax.
    - GitHub release notes link the README quickstart; `sentwise.ai/download` resolves to the 0.2.1 DMG.
    - Item 114 resolves when TC-M1-01 shows notes in the dialog on a 0.2.0 install.
    - **Verified by:** TC-M1-01, TC-M1-02, TC-M1-10.

118. **Checkout-intent counter on the Worker (`sentwise-service`)** — *(M2, High)*
    Count when a signed-in account opens checkout or a plan change, so the funnel has a stage between "trial started" and "paid".
    *As the maintainer, I want to see how many trial users open checkout, so that I can tell a pricing problem from a product problem.*
    - `/v1/paddle/checkout` and `/v1/paddle/change-plan` write one Analytics Engine datapoint per call: HMAC-hashed account id (same scheme as `analytics.ts`), action, requested tier, trial/paid state. No email, no payment data.
    - The counts surface in item 88's `GET /admin/funnel` as `checkoutsOpened.{starter,pro,unlimited}` (both actions, by requested tier; same shape as `subscriptionsActivated`). Each tier counts **unique accounts**, not calls: `/admin/funnel` deduplicates by the stored HMAC account id within the requested date range, so retries, repeat clicks, and repeated plan changes from one account to the same tier count once. An account that requests two tiers counts once in each. No separate attempts count is exposed.
    - Comp accounts (item 111) and calls that fail auth are not counted.
    - Each datapoint carries item 88's population tag. Checkouts by QA-domain accounts (`QA_EMAIL_DOMAINS`) count only in `/admin/funnel`'s `qa.checkoutsOpened.*`, never in the live `checkoutsOpened.*`. Checkouts opened from the QA build reach only the sandbox deployment (item 123) and its own dataset.
    - Vitest: datapoint written once per successful call, never on 401, never for comp; `/admin/funnel` counts two Starter checkouts from one account as `checkoutsOpened.starter` = 1, and a Starter then a Pro checkout from one account as 1 in each tier.
    - **Verified by:** TC-M2-05, TC-M2-07, TC-M2-08.

119. **QA trial override: admin route to set a test account's trial start (`sentwise-service`)** — *(M3, High)*
    Let QA put a throwaway account at any point of the 14-day trial, so trial reminders and the trial-ended path can be tested in minutes instead of two weeks.
    *As QA, I want to set a test account's trial start date, so that I can verify the 7-day, 1-day, and trial-ended states on production builds.*
    - `POST /admin/trial` with `{email, startedAt}` behind the existing `authorizeAdmin` gate (`ADMIN_TOKEN`; invisible 404 when unset, 401 otherwise).
    - Only emails whose domain is in a Worker var `QA_EMAIL_DOMAINS` (initially `prowlqa.dev`) can be changed; anything else returns 403 `trial_override_forbidden` and writes nothing.
    - Writes only `privateMetadata.trialStartedAt`; returns the computed trial state; an audit datapoint like item 111's `admin_comp_*` (hashed id, action).
    - Never alters an account with a real Paddle subscription or an active comp (409).
    - README documents the curl with a `$ADMIN_TOKEN` placeholder. Production deploy is Michael's.
    - **Verified by:** TC-M3-01, TC-M3-02, TC-M3-04.

120. **Release v0.2.2 (trial reminders and scheduled cancellation)** — *(M3, High)*
    Ship items 87 and 92 in a signed release so the trial-to-paid path can be verified on production.
    *As a trial user, I want the release that warns me before my trial ends and shows my cancellation date, so that billing never surprises me.*
    - `/release-prep` 0.2.2 after 87, 92, 119 (deployed), 124, and 123 (sandbox deployment live, QA build configuration merged) are in; the 0.2.2 tag is then deployed to the sandbox Worker and cut as a QA build; CHANGELOG section written; appcast notes present; cask bumped.
    - Item 87's notification copy follows TC-M3-02/03 ("Your Sentwise trial ends in 7 days", "Your Sentwise trial ends tomorrow"); item 92 shows "Cancels on <date>".
    - **Verified by:** TC-M3-05, TC-M3-06 (purchase in the 0.2.2 QA build against the sandbox deployment, item 123).

121. **Continue with Google: TC-M4-03 verification on Lucius' Mini** — shipped in PR 125 (see docs/resolved.md); only the TC-M4-03 production check on Lucius' Mini remains.

122. **Release v0.2.3 (first-run friction)** — *(M4, High)*
    Ship items 110, 105, and 121 in a signed release before the public link goes out.
    *As a first-time user from the public link, I want onboarding to recognize my company mailbox and let me sign in with Google, so that I reach my first draft without help.*
    - `/release-prep` 0.2.3; CHANGELOG section; appcast notes; cask bumped.
    - Item 106's Clerk email branding is live before the release is announced (dashboard work, no app code).
    - **Verified by:** TC-M4-06 (and TC-M4-01 to TC-M4-05 on this build).

123. **QA purchase path via a sandbox deployment of sentwise-service** — *(M3, High; Michael 2026-10-12: build it now; re-scoped 2026-10-13)*
    The comp entitlement (111) skips checkout, so nothing proves the paid path end to end. TC-M3-05 is blocked at the payment step until a test method exists.
    > **Re-scoped 2026-10-13 (genkei-ops decision of that date):** the first design, a per-account Paddle lane inside the production Worker, was abandoned after six review rounds kept finding timing windows between out-of-order Paddle webhooks, Clerk metadata, and the Durable Object. Its `paddle-sandbox-lane` branches were closed unmerged. The production Worker now carries **no sandbox state at all**: no `PADDLE_ENV` switch, no per-account lane, no lane lock, no lane-reset route, no lane fields in `/v1/me`. The two production bugs that work uncovered are item 124.
    *As the owner, I want QA to complete a real checkout on a test account every release, so that the one flow that makes money is never the one flow nobody tests.*
    - **Second Worker deployment (`sentwise-service`):** a `wrangler` environment `sandbox` in `wrangler.jsonc` with its own Worker name (`sentwise-inference-sandbox`) and its own `workers.dev` hostname, its own Durable Object namespace (`ACCOUNT_QUOTA` is per-Worker), its own KV namespaces if any are added, and its own Analytics Engine dataset (for example `sentwise_usage_sandbox`) so no sandbox datapoint can land in the production funnel. Secrets for that environment: Paddle **sandbox** API key, sandbox webhook secret, sandbox price IDs mirroring the tier matrix, Clerk **development instance** keys, `ADMIN_TOKEN` (a different value from production), and an inference provider key (a separate key with a low spend cap). `QA_EMAIL_DOMAINS` is set the same as production. The code is identical to production; only configuration differs.
    - **Deploy:** a `scripts/` deploy script (`wrangler deploy --env sandbox`) and a **dispatch-only** CI job (`workflow_dispatch` with a `ref` input; never on push) in its own GitHub environment `sandbox`, running the same lint/typecheck/test gate as the production deploy. The Paddle sandbox webhook points at the sandbox hostname only.
    - **QA build of the app (`sentwise`):** a `QA` build configuration driven by an xcconfig: bundle identifier suffix `.qa`, app name **Sentwise QA**, status item accessibility label "Sentwise QA", its own Keychain service (derived from the bundle identifier, so it never reads or writes the production app's `com.tookes.Sentwise` items; see item 115), a Sparkle updater that is never started (below), service base URL pointing at the sandbox hostname, and Paddle client config for the sandbox environment, and the **Clerk development instance's Frontend API URL** (plus its publishable key, if the app uses one), all from the xcconfig. The Clerk setting matters on its own: `ClerkClient` defaults to `https://clerk.sentwise.ai` and signs in against Clerk directly, so pointing only the service URL at the sandbox would create F3 in production Clerk. It installs as `/Applications/Sentwise QA.app` and coexists with the production install on the QA Mini.
    - **No self-update in the QA build (Codex P2, 2026-10-13):** the guarantee is that the QA build **never starts its Sparkle updater** (`UpdateManager.startUpdater` returns early when `BuildConfiguration.allowsAutomaticUpdates` is false), so neither a scheduled check nor a manual one can fetch the production appcast and replace the QA install with a production build. Turning off automatic checks alone would not be enough, because the About pane and the status menu call `checkForUpdates()` directly. Both manual entry points must stay **disabled** in the QA build: About shows **Check for Updates…** disabled with "Updates are turned off in QA builds.", and the status menu shows **Check for Updates (Unavailable)** disabled. Verified by TC-M3-05 step 8.
    - **Local data isolation (Codex P1, 2026-10-13):** a separate bundle identifier and Keychain service are not enough, because `PersistenceService.init()` hardcodes `~/Library/Application Support/Sentwise` (`docs/local-data.md`). Every per-app location is derived from the build instead of hardcoded: the Application Support directory (`~/Library/Application Support/Sentwise QA` for the QA build), the UserDefaults suite or domain, caches, logs and `Logger` subsystem, temporary files, and any other per-app identifier. **Erase all local data** and the item 96 purges in the QA build touch only the QA build's directory and Keychain service. Unit test: the persistence root, defaults suite, and Keychain service resolve from the bundle identifier, and the production configuration still resolves to the existing `Sentwise` paths, so current users' data stays where it is.
    - **URL scheme isolation (Codex P2, 2026-10-13):** the QA build registers `sentwise-qa://` only and never `sentwise://`, so macOS cannot route a production sign-in or OpenRouter callback to the QA app. The scheme comes from the xcconfig; the Worker's `/auth/callback` and `/openrouter/callback` landing pages forward to a scheme read from a Worker var (`sentwise` on production, `sentwise-qa` on the sandbox deployment), and the sandbox's Clerk development-instance redirect allowlist uses the sandbox hostname. The app's callback parser accepts only its own build's scheme. A dispatch-only workflow builds it from a given tag, signed and notarized like a release, as a workflow artifact; it is never published to the appcast, the cask, or a GitHub release. The production build configuration is unchanged.
    - **Lockstep:** every release tag is deployed to both Workers (production by the existing deploy, sandbox by dispatching the sandbox job with the same tag), and the QA build is cut from the same tag as the release it verifies. `docs/billing-qa.md` records the procedure and the currently deployed sandbox tag.
    - Document the Paddle sandbox catalog, the Clerk development instance, the sandbox hostname, and where test card numbers live in `docs/billing-qa.md`; secrets stay in the Worker's env and GitHub environment secrets, never in docs. Vendor setup (sandbox catalog, webhook, Clerk dev instance) goes through `/vendor-config`.
    - Fallback test methods, **only if the sandbox deployment slips**, in order: a single-use 100%-off Paddle discount code on production; a real $9 Starter purchase refunded the same day.
    - Done when sign-in and session-token minting in the QA build go to the Clerk development instance (no request to `clerk.sentwise.ai`; F3 exists in the development instance and not in production Clerk, checked in TC-M3-05 step 7), TC-M3-05 runs green on the sandbox deployment from the QA build, TC-M3-11 shows the production install's data byte-identical across the QA run, and TC-M4-03 shows the production Google sign-in returning to **Sentwise** with the QA build installed.
    - **Verified by:** TC-M3-05, TC-M3-11, TC-M4-03 (and TC-M3-06 to TC-M3-10 run on the same deployment).
    - **Progress 2026-10-18:** the sandbox Worker (`sentwise-inference-sandbox`, `workers.dev`) is deployed from `main` with all four `SANDBOX_*` GitHub secrets set; the dispatch-only deploy run is green and `/healthz` answers 200. Remaining for this item: the QA build checks and TC-M3-05 green against it. The deploy smoke check now retries during `workers.dev` propagation (sentwise-service item 3, branch `sandbox-smoke-retry`).

124. **Production billing fixes found during the lane work** — *(M3, High; found 2026-10-13 in the abandoned item 123 lane branches)*
    Two production defects surfaced while building the per-account lane; they are cherry-picked onto small branches in each repo, independent of the sandbox deployment.
    *As a paying user, I want my subscription state and plan buttons to reflect what Paddle actually says, so that a paused plan reads as paused (resumable from Manage billing) rather than canceled, and I cannot click into a broken checkout.*
    - `sentwise-service`: a paused subscription was stored as `canceled`. Keep Paddle's raw `status` in the stored subscription; `/v1/me` reports it as paused, not canceled. A paused subscription is **not** entitled to draft (Paddle stops billing while paused), so draft requests return 402. Vitest: a `subscription.paused` webhook stores `paused` and drafting returns 402; a later `subscription.resumed` returns it to `active` and drafting works again.
    - `sentwise`: the Subscription pane's plan-change buttons (**Subscribe**, plan cards, **Manage plan**) could be enabled while `/v1/me` is still loading and no Paddle config is present. Disable them until the Paddle config is loaded; show the existing loading state meanwhile. Unit test: buttons disabled with no Paddle config, enabled once it loads.
    - `sentwise`, paused handling on the client: decode `paused` from the service's `paddleStatus` in `/v1/me` (today the app has no paused state); the Subscription pane shows exactly "Paused — your <Plan> subscription is paused. Resume it in Manage billing." with **Manage billing** available and **Subscribe** and the plan cards hidden; drafting is refused while paused, matching the Worker, and returns after resume. Regression tests: `paused` decodes to the paused state, the pane renders that string with only **Manage billing**, and drafting is refused while paused and allowed after resume; `active`, `canceled`, and scheduled-cancel rendering are unchanged.
    - Shipped in v0.2.1 (PR 107) and the matching Worker deploy.
    - **Verified by:** TC-M3-10 (paused status on the sandbox deployment); TC-M3-05 steps 2–3 for the buttons (they open a working checkout once loaded; the disabled-while-loading state is covered by the unit test, since QA cannot hold `/v1/me` mid-load).

129. **Item 74 Slice A — production Paddle cutover and real-dollar paid-path proof** — *(High; first launch slice; US-launch-readiness-1)*
    Close the last money-path uncertainty under item 74: current code/config already selects live Paddle, but no non-comp production trial has completed a real-dollar purchase and then opened a fresh authenticated customer portal session.
    *As a trial user, I want live checkout to activate the plan I paid for and open billing management without another sign-in, so that I can safely become a paying customer.*
    - **Builder:** verify the signed production build selects `PaddleConfig.production`, the Worker uses `https://api.paddle.com`, all three distinct live price IDs match `docs/tier-matrix.md`, and production cannot fall back to sandbox or proceed with blank/mismatched config. Preserve item 94: trials are hard-enforced in code while paid tiers may remain `ENFORCEMENT_MODE=soft`; no global hard-mode flip without an owner decision.
    - **Vendor-ops:** through the Paddle API/runbook, verify the live $9/$19/$39 monthly USD catalog, approved `sentwise.ai` domain, production webhook/events, live client token metadata, and an API key carrying `customer_portal_session.write` (item 91). Record redacted metadata/permissions only, never values.
    - **Michael gate:** no live charge, production secret replacement, refund, or paid launch proceeds until Michael writes **production approved**. After approval, use one controlled non-comp account whose domain is not in `QA_EMAIL_DOMAINS` to buy Starter for the displayed real amount on Lucius' Mini; Michael decides whether it remains active or is refunded/canceled.
    - Acceptance: the live transaction is attributed by the webhook; the app changes Trial → Starter; a managed draft succeeds; `/admin/funnel` increments live Starter activation and not `qa`; **Manage billing** opened twice produces fresh no-store portal-session links that land signed in without an email/magic-link prompt. Evidence redacts account, payment, transaction, customer, receipt, and portal URL.
    - Unhappy path: without **production approved**, QA blocks before submitting payment. Declined/abandoned payment, failed webhook, empty secret, missing permission, or sandbox/mismatched config grants no paid entitlement and produces an actionable failure; no live paid activation is recorded.
    - **Size/order:** S (about 1 builder day if drift exists, 0.5 vendor-ops day, owner approval window, 0.5 QA day). This is the first slice and the critical-path gate to a paid purchase; Slice 130 may run in parallel.
    - **Verified by:** TC-74-08 in `docs/requirements/launch-readiness.md`.

130. **Item 74 Slice B — clean-Mac first-run and first-value verification** — *(High; second launch slice; US-launch-readiness-2)*
    Prove the stranger path in a fresh macOS user account on Lucius' Mini, not on a maintainer machine, and turn every confirmed friction point into a stable backlog item before this slice closes.
    *As a first-time Mac user, I want to install Sentwise and approve an inbox reply and post-call follow-up without maintainer help, so that I can judge the trial before paying.*
    - Execute the predetermined TC-74-01 through TC-74-07 list in `docs/requirements/launch-readiness.md`: quarantined browser DMG through Gatekeeper/notarization; warning-free Homebrew cask; production sign-in + Gmail app password; voice learning; first inbox reply; first pasted-transcript follow-up opened from the notification and approved only in Review Drafts; previous-version Sparkle update with human notes. The 14-day Trial assertion occurs only after the first authenticated draft request and a Subscription refresh, matching TC-M1-08 step 8; sign-in alone does not start the trial.
    - Negative states are part of acceptance: invalid/expired sign-in, bad/revoked app password, notification denial, offline inference, missing voice samples, dismissed notification, and update-signature failure must be explicit and recoverable; no connected/learned/sent/saved/paid success may be claimed when it did not occur.
    - Michael performs only protected admin/TCC steps through Jump Desktop: authorize/create the fresh user if required, grant Lucius' Accessibility and Screen & System Audio Recording access, and handle Sentwise Notification permission if automation cannot drive the macOS prompt. Credentials never enter transcripts or evidence.
    - Every warning, extra unexplained step, inaccessible control, dead end, or misleading state is linked to an exact existing ID (including 109, 110, 112–116 where applicable) or filed as a new stable backlog item with priority, reproduction, expected/actual, evidence, mapped TC-74 case, and Given/When/Then fix criteria. Item 130 stays open until that triage is complete.
    - Evidence uses only the synthetic fixtures in `docs/qa/test-cases.md` and redacts addresses, codes, app passwords, mail/transcript text, and personal paths.
    - **Size/order:** M (1–2 QA days plus finding intake). Starts in parallel with 129 but must pass before release Slice 131.
    - **Verified by:** TC-74-01 through TC-74-07 in `docs/requirements/launch-readiness.md`.
    - **Run 1 (2026-10-27/28, Lucius, clean Mac): 0 PASS / 3 FAIL / 4 BLOCKED (strict evidence gate); negatives 2 PASS (N2a, N6a) / 0 FAIL / 8 not tested or incomplete.** Signed DMG 0.2.1 on macOS 26.4.1, in a reset existing account (Option B), not a never-used Mac; notification permission could not be reset (`tccutil` refused), so the first-run notification check is not clean. Report and evidence: Lucius' `sentwise-qa/runs/2026-10-27-sentwise-130-clean-mac/report.md`. Zero sends, zero purchases.
      - TC-74-01 BLOCKED: download, checksum, Gatekeeper, notarization (Developer ID, Genkei Labs LLC, stapled) and first run pass functionally; no video.
      - TC-74-02 FAIL: the first `brew install` was a no-op on a stale Caskroom receipt; after uninstall the retry installed 0.2.1 and reached first run, but the log shows an untrusted-tap warning for `oven-sh/bun` (unrelated) and the ContainerBar cask deprecation (item 141). The Sentwise cask itself printed nothing. Proposed case amendment in `docs/qa/test-cases.md` (TC-74-02 note).
      - TC-74-03 FAIL: F2 sign-in and F1 Gmail app-password connection succeed; the Workspace domain was not auto-detected (item 110, which merged 2026-10-26 after 0.2.1 was tagged, so expected on this build); notification first-run and the full negative set incomplete.
      - TC-74-04 BLOCKED: learning and persistence after relaunch pass functionally; no video; N4 (offline) not run. Found item 140 (app-menu Settings blank).
      - TC-74-05 BLOCKED: Q1 was never sent, so no inbox reply was drafted; before any draft the account already showed Trial 14 days and 1 of 400 drafts used (item 139).
      - TC-74-06 FAIL: two T1 drafts; draft 1 denied, draft 2 approved once and saved to Drafts (no send); both have the wrong greeting and owner, draft 2 drops 10 seats and 30 days (item 138). Notification Open path not observed.
      - TC-74-07 BLOCKED: Sparkle 0.2.0 → 0.2.1 with human notes, install and relaunch, notarized; mailbox, voice, Save as draft and trial persist; missing pre-update assertions, post-update draft comparison and video.
      - Not product defects: F1 app-password fixture needed normalizing; Peekaboo typing, paste and focus failures; missing videos; a Keychain prompt at reset after Debug activity on the same Mini (noted on item 115 in `docs/resolved.md`).
    - **Before Run 2:** (1) reinstall from the release under test, because prowl-qa CI ran on that Mini after Run 1 and Debug builds share the production Keychain service; (2) Michael sends Q1 and gives the send time; (3) discard the one saved "Pilot next steps" draft in F1's Gmail Drafts (12:48 PM 2026-10-28) after copying its body into the run evidence for item 138, and trash the run's Q1 if it arrived; (4) continuous video for every case; (5) an F2 with a new RUNID, and a way to type the sign-in code that Peekaboo accepts (Run 1 lost most of a day to code transfer). Run 2 should use the 131 release candidate, which will contain items 110, 138, 139 and 140.
    - **131 blockers from Run 1:** 138 (wrong facts in the flagship follow-up), 139 (trial and quota start before the first draft; blocks until Michael decides the rule, then fixed or the cases amended), 140 (blank Settings window from the app menu). Not blockers: 141 (P3 tap warning from another app's cask), 110 (fixed on main; re-verify in Run 2), the stale receipt and untrusted-tap warnings (test-case change), and the harness problems above. Item 130 stays open until Run 2 passes.

131. **Item 74 Slice C — launch release hygiene and non-maintainer verification** — *(High; third/final launch slice; US-launch-readiness-3)*
    Cut the owner-approved launch release only after Slices 129/130 pass, then prove every public distribution channel delivers the same trusted artifact and that support/update trust is live.
    *As a prospective customer, I want the public download, Homebrew cask, and automatic update to deliver the same trustworthy release with understandable notes and reachable support, so that I can install and get help confidently.*
    - Resolve the version gate before tagging: this item is specified as **1.0.0 via `/release-prep`**, but the recorded 2026-10-22 owner direction says Sentwise remains on 0.x for now and puts pre-launch work into 0.2.3; the earlier 1.0.0 was yanked. Michael's explicit launch-version/release approval is required and the approved version must match project metadata, CHANGELOG, tag, GitHub release, DMG, cask, and appcast.
    - Run `/release-prep` through the existing CI tag pipeline with a human-written CHANGELOG section and GitHub release notes that summarize user-visible changes and link README **Quickstart** (item 71). Missing notes, signing/notarization failure, or an invalid/placeholder Sparkle key fails closed before publishing.
    - On Lucius' Mini, verify `sentwise.ai/download`, Homebrew cask, and the appcast all resolve to the same version/build; Gatekeeper accepts the DMG; cask checksum matches; a previous signed version updates with non-empty human notes and retained state. A mismatch blocks the public-link step.
    - Confirm `feedback@sentwise.ai` remains monitored by sending the redacted QA diagnostic fixture and observing receipt within one hour. Confirm the built app's `SUPublicEDKey` matches the public key derived from the offline private key; evidence contains only a public fingerprint/match result and the private key never moves to the repo or QA machine.
    - Update the existing `docs/launch-checklist.md` with dated artifact/evidence references; do not tick live gates from code review alone. Item 131 closes after release verification; umbrella item 74 closes only when the owner-approved public link goes out.
    - Unhappy path: any wrong build, missing support mail, signature/update failure, or open P1/P2 launch defect blocks announcement while the last known-good release remains available and a TC-linked backlog defect is filed.
    - **Blocked by:** sentwise-service production deploy of 139 (approved 2026-10-28) and the sentwise#130 rerun.
    - **Size/order:** M (1 release day plus 0.5–1 QA day). Final slice; depends on 129 and 130.
    - **Verified by:** TC-74-09 and the TC-74-07 update leg in `docs/requirements/launch-readiness.md`.

132. **Preserve a host typed before the email address when a Workspace MX suggestion arrives** — *found 2026-10-26, final Codex review of item 110 (P2), filed as a follow-up under the three-round cap*
    Item 110 preserves explicit IMAP hosts that are already associated with the current address, but a host typed before the email is completed (`mailHostExplicitlyEditedBeforeEmail` true, `mailHostWasExplicitlyEditedForCurrentAddress` false) still passes the suggestion guard in `AppState+MailProvider.swift` around lines 102-105. A successful MX lookup that lands during typing replaces that host (for example `imap.mail.me.com`) and clears its ownership tracking, bypassing the pending-host preservation that `updateMailEmailFromUser` and `AppStateMailProviderPendingHostTests` cover.
    *As a user who types my IMAP host before my address, I want an automatic Google Workspace suggestion to leave my host alone, so that nothing I entered on purpose is silently overwritten.*
    - The MX-suggestion apply path treats a pending explicit host (edited before the email was complete) the same as a host explicitly edited for the current address: it is never replaced and its ownership flags are never cleared.
    - Unit test: type `imap.mail.me.com` with the email still incomplete, then let a successful Workspace MX lookup resolve; the host and its explicit-edit flags are unchanged.
    - Existing `AppStateMailProviderPendingHostTests` and the item 110 tests stay green.
    - **Build note 2026-10-26 (`132-preserve-pending-host`):** the Workspace MX apply guard now treats `mailHostExplicitlyEditedBeforeEmail` as explicit ownership, preserving the typed host and both ownership flags. `AppStateMailProviderPendingHostTests` covers a successful Google-hosted MX result while the host remains pending. SwiftLint strict and `xcodebuild build-for-testing` pass locally; the unit suite runs in CI.

133. **Presentable Google sign-in finish page** — *requested by Michael 2026-10-26 during the item 104 live check*
    After Google consent the loopback listener in `OAuthRedirect.swift` answers with a plain-text line. Replace it with a self-contained HTML page matching the managed sign-in handoff card in sentwise-service `src/callback.ts` (same layout, type, colors, light and dark), with a success and a failure variant.
    *As a user connecting Gmail, I want the browser tab after Google consent to look like Sentwise finished the job, so that I trust the sign-in and know to return to the app.*
    - Success (query has `code`): check badge, heading "Signed in with Google", sub text "Sentwise is connecting your mailbox. Return to the app to continue.", a "Return to Sentwise" button that opens the app (the app's existing URL scheme), hint "You can close this tab."
    - Failure (query has `error`, for example access_denied): red cross badge, heading "Google sign-in didn't finish", sub text "Sentwise did not receive access. Return to the app and try again.", same button and hint. Any other request (no `code`, no `error`) gets the failure page.
    - The page is a stored constant in Swift, served as `text/html; charset=utf-8` with the correct Content-Length and `Connection: close`; no external resources, no JavaScript needed, no query value is ever reflected into the HTML.
    - Unit tests on the response: content type, status, success body for a `code` request, failure body for an `error` request, no echo of the `code`, `state` or `error` values; existing `OAuthRedirect` tests stay green.
    - Visual check deferred to the v0.2.3 QA pass on Lucius' Mini.
    - **Build note 2026-10-26 (`133-google-signin-finish-page`):** `OAuthRedirect.swift` now serves stored, self-contained success/failure HTML cards with the managed handoff's light/dark styling, exact UTF-8 response framing, and no reflected query values. `LoopbackRedirectListenerTests` covers both variants and headers. Because the app has no plain open-only deep-link host, **Return to Sentwise** targets the current build's URL-scheme root (`sentwise://` in production; the isolated QA scheme in QA builds). Visual verification remains in the v0.2.3 Lucius QA pass.

134. **Google OAuth client published and CASA-verified** — *(High; gates the public launch and item 135; filed 2026-10-28 from the owner decision "Sentwise connects with sign-in, not app passwords"; US-sign-in-first-5)*
    Move the Sentwise Google client from Testing (100 users, 7-day token expiry) to In production, pass restricted-scope verification for `https://mail.google.com/`, and obtain the CASA Tier 2 Letter of Validation. Steps in `docs/gmail-oauth.md` sections 4-5. Owner: vendor-ops prepares the submission (genkei-ops backlog 31); Michael publishes the consent screen, submits, and pays the lab. Google review 2-6+ weeks.
    *As the owner, I want the Google client published and CASA-verified, so that any Gmail user can sign in with no cap or interstitial.*
    - Acceptance criteria: brief section 5 (non-test-user sign-in shows no unverified-app interstitial; refresh token older than 7 days refreshes; `invalid_grant` shows "Sign in with Google again").
    - Evidence recorded in `docs/launch-checklist.md` (status and LoV reference, no secrets); annual renewal on the calendar.

135. **Hide the app-password field behind "Other ways to connect"** — *(High; gated on 134 for the public channel; filed 2026-10-28; US-sign-in-first-1 to 4; brief `docs/requirements/sign-in-first.md` section 4)*
    When Google sign-in is available, the connect UI (onboarding account step and Settings > Account) shows only "Continue with Google" plus a collapsed "Other ways to connect" disclosure holding the existing app-password form and "Advanced (IMAP server)". iCloud, Yahoo, AOL, AT&T and custom hosts stay reachable; the IMAP engine, host suggestion and credential guidance stay unchanged. Existing app-password accounts keep working. If Google sign-in is unavailable (no client id, Prowl hunt mode) the app-password form is shown directly.
    *As a new Gmail user, I want only "Sign in with Google", so that I never meet an app password.*
    - Build behind a flag that defaults to the current UI; the flip to the public channel requires 134 done and an owner-approved step. UX review and copy from the ui-designer folded into the brief.
    - Unit tests: view model shows/hides the form per flag and `isGoogleSignInAvailable`; existing-account Settings path; disclosure accessibility label and state.
    - **Verified by:** test cases to be added by project-planner (first-run Gmail, iCloud via disclosure, upgrade with existing app-password account).
    - Technical tasks (architecture `docs/architecture/sign-in-first.md` sections 4.7, 5.1, 11):
      - T135-1 Flag `SENTWISE_SIGN_IN_FIRST` (new `Sentwise/Config/SignInFirst.xcconfig`, empty) -> Info.plist `SentwiseSignInFirst` -> `BuildConfiguration.signInFirst`; `QA.xcconfig` sets `YES`. Hide applies only when the flag is on and `isGoogleSignInAvailable`.
      - T135-2 Email field moves outside the disclosure, shared with the app-password form; Google uses it as `login_hint`.
      - T135-3 Hidden state in `GoogleOrAppPasswordConnect` for onboarding and Settings; disclosure "Other ways to connect", identifier `otherWaysToConnect`; existing identifiers kept.
      - T135-4 Onboarding subtitle per state (copy from the UX review).
      - T135-5 Inline provider hints (no auto-expand), including the Microsoft note until item 31 ships.
      - T135-6 `SavedMailAccount.authProvider` with launch back-fill; Settings expands the disclosure for app-password accounts.
      - T135-7 Release wiring: repository variable `SENTWISE_SIGN_IN_FIRST`, set only by the owner after 134 is done; release-checklist line.
      - T135-8 View-state tests: flag off; flag on with Google; flag on without Google; existing app-password account; Microsoft-domain note.

136. **Azure / Entra app registration and publisher verification for Microsoft sign-in** — *(Medium; prerequisite for item 31; owner + vendor-ops; filed 2026-10-28; brief section 6, questions A1, A2, A8)*
    Create the Microsoft Entra app registration (public client, loopback redirect, scopes per the architect), publisher domain and publisher verification, and record the client id in the build config. Michael owns the tenant and any verification payments.
    - Done when the architect's A1/A2 answers are implemented in the registration and a personal-account sign-in works against it.
    - Technical tasks (architecture `docs/architecture/sign-in-first.md` sections 5.5, 10 A1, R2):
      - T136-1 Multi-tenant + personal registration (`AzureADandPersonalMicrosoftAccount`), public client flows on, platform "Mobile and desktop applications", redirect `http://localhost`; delegated permissions Office 365 Exchange Online `IMAP.AccessAsUser.All`, `SMTP.Send`, plus `offline_access`, `openid`, `email`; no client secret.
      - T136-2 Publisher domain sentwise.ai via `/.well-known/microsoft-identity-association.json` on the landing page.
      - T136-3 Microsoft AI Cloud Partner Program ID for Genkei Labs LLC and publisher verification.
      - T136-4 Client ID (a GUID, not secret) stored as repository secret `SENTWISE_MICROSOFT_CLIENT_ID`; never committed.
      - T136-5 Confirm the redirect accepts a random loopback port with `http://localhost`; if not, register `http://127.0.0.1` in the manifest and report to the builder.

137. **Google consent-screen logo (120x120)** — *(High; gates Google verification and therefore 134/135; filed 2026-10-28; owner ui-designer, Michael approves)*
    Design the Sentwise app logo for the Google OAuth consent screen: square PNG, exactly 120x120 px (Google accepts up to 1 MB, JPG or PNG, square), the owl mark on a plain background, legible at small size in light and dark consent screens, matching the brand in the landing page and app icon.
    - Acceptance: Given the file, Then it is 120x120 px PNG under 1 MB, square, with no transparency artifacts on white or dark backgrounds, no Google trademark or misleading text; the owner approves it; vendor-ops uploads it to the consent screen (branding) and the read-back shows it.

141. **ContainerBar cask in the shared tap prints a deprecation warning during `brew install --cask michaeltookes/tap/sentwise`** — *(Low, P3; does not block 131; found 2026-10-27 by the item 130 clean-Mac run, TC-74-02; owner builder, change lands in `michaeltookes/homebrew-tap`)*
    Homebrew 7.0.11 loads every cask in the tap and prints "Calling string comparison format for `depends_on macos:` is deprecated!" for `Casks/containerbar.rb` line 11 (`depends_on macos: ">= :sonoma"`) to anyone installing Sentwise. The Sentwise cask is already fixed (`depends_on macos: :sonoma`, item 116). Evidence: `02-brew-install.log`, `02-brew-install-retry.log` in the run folder.
    *As a Sentwise installer, I want the Homebrew install to print no warnings about other apps, so that the install looks trustworthy.*
    - Given the tap at its current main, When `brew install --cask michaeltookes/tap/sentwise` runs on Homebrew 7.x, Then no `depends_on macos:` deprecation warning is printed for any cask in the tap.
    - Unhappy path: Given ContainerBar's next release regenerates its cask, Then the release template writes the symbol form, so the warning does not return (check the ContainerBar release script or cask template).

142. **Follow-up participant matching: token match must not contradict the sender's surname** — *(Medium, P3; found 2026-10-28 by Codex review of item 138; owner builder)*
    `FollowUpParticipants.userSpeaker` matches a transcript label to the sender by first-name token. With sign-off "Alex Taylor", mailbox alex.taylor@example.com and labels "A. Taylor" and "Alex Chen", the token match picks "Alex Chen", assigning another person's commitments to the sender. Safe fix: require the full name, or reject any token match whose surname conflicts with the sender's, and leave ownership unresolved (the unlabeled-transcript behaviour).
    - Given sign-off "Alex Taylor", mailbox alex.taylor@example.com and labels "A. Taylor" and "Alex Chen", When the participants are resolved, Then "Alex Chen" is not chosen as the user and ownership is unresolved (or "A. Taylor" is chosen only on a full-name match).
    - Unhappy path: Given labels "Alex Chen" only, Then ownership stays unresolved and the prompt does not claim a speaker for the user.
    - Same class (Codex, final pass on 1723290): Given sign-off "Alex" and labels "Alex (Sales)" and "Alex (Acme)", When affiliations are stripped and labels deduplicated, Then the two participants must not collapse into one "Alex" that resolves as the user; track normalisation collisions and leave ownership unresolved.