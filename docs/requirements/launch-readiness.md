# Launch readiness slices (item 74)

**Status:** build-ready requirements, 2026-10-22
**Umbrella:** sentwise#74
**Backlog slices:** 129 (A), 130 (B), 131 (C)
**Business outcome:** a person outside the company can download Sentwise, start the no-card trial, and become the first paying customer without maintainer help.

## Problem

Sentwise has no paying users. Michael decided on 2026-10-14 that the `icp-finder` run starts the day a stranger can download the app, start a trial, and pay; on 2026-10-22 he made the first paying Sentwise customer the company's top priority. The app and service have substantial launch plumbing, but item 74 still combines three different kinds of work: production billing proof, clean-machine experience proof, and release operations. That combination cannot be assigned or verified independently.

The risk is not mainly missing code. Live Paddle configuration, signed/notarized distribution, the monitored feedback mailbox, and most security remediation already exist. The remaining risk is that the paths have not all been proven together under stranger-like conditions: no prior local state, a real non-comp trial account, a real-dollar live transaction, a fresh portal session, and a final release consumed from outside the maintainer's machine.

Evidence reviewed:

- `docs/backlog.md` item 74 and related items 123, 56, 91, 94, 95, 96, and 71.
- `docs/security-pass-2026-09-13.md` and `docs/launch-checklist.md`.
- Git history and `docs/resolved.md`: **94 landed and was deployed** (`security-hardening`, PR #21); **95 landed** (`checkout-hardening`, PR #81) and its checkout overlay was live-verified; **96 landed** (`local-mail-purge`, PR #83). They are not launch work to rebuild.
- Current shipped state: `PaddleConfig.active` resolves to production; live price IDs are embedded; the Worker uses live Paddle; the secret-hygiene checks, `feedback@sentwise.ai`, and the Sparkle public/private key match are recorded complete. Those controls need release-candidate regression evidence, not reimplementation.

## Goal and non-goals

### Goal

Close item 74 through three independently assignable slices, ordered by distance to a paid purchase:

| Rank | Slice | Backlog | Outcome | Estimate | Can start |
|---|---|---:|---|---|---|
| 1 | **A — production Paddle cutover and paid-path proof** | 129 | A controlled live trial account completes a real-dollar purchase and opens a fresh authenticated portal session; its funnel event is `live`. | **S:** 1 builder day for configuration/guards if drift is found, 0.5 vendor-ops day, one owner approval window, 0.5 QA day | Now, except the charge waits for Michael's written **production approved** |
| 2 | **B — clean-Mac first-run verification** | 130 | Both install paths and the complete first-value workflow pass in a fresh macOS user account on Lucius' Mini; every friction point has a stable backlog ID. | **M:** 1–2 QA days plus intake time for findings | Now, in parallel with A |
| 3 | **C — release hygiene and launch checklist** | 131 | The owner-approved launch version is released with human notes; DMG, cask, appcast, support address, and update signature are proven from a non-maintainer machine. | **M:** 1 release day plus 0.5–1 QA day | Preparation now; final tag after A and B pass |

**Critical path:** Michael says **production approved** → vendor-ops confirms the live Paddle catalog/key/webhook → builder fixes only any detected configuration drift → Lucius/CI completes the real-dollar trial-to-paid and portal-session proof (Slice A) → Slice B's clean first-value cases pass and all friction is filed → Michael approves the launch version/release → `/release-prep` and non-maintainer distribution verification complete (Slice C) → public link goes out and item 74 closes. Slice B runs in parallel with Slice A until both feed the final release gate.

### Non-goals

- Rebuild items 56, 71, 91, 94, 95, or 96.
- Redesign checkout, onboarding, Review Drafts, notifications, or the Subscription pane unless a predetermined case finds a defect.
- Add Zoom/Teams integration, native capture, Outlook, Google Gmail OAuth/CASA, Slack, CRM, or new telemetry.
- Run a purchase, GUI test, browser test, app launch, or device test on Michael's MacBook or Mac Mini.
- Put secrets, card data, customer data, mailbox addresses, or raw mail/transcript content in the repository or test evidence.
- Send the public launch link; item 74 remains the umbrella and closes only when the orchestrator records that separate owner-approved action.

## Users and roles

- **New trial user (Marcus/Priya):** installs Sentwise on a Mac with no Sentwise history, connects Gmail with an app password, receives useful drafts, and chooses a paid plan.
- **Paying user:** sees the paid entitlement after checkout and reaches billing management without another email sign-in.
- **Michael (owner/finance):** approves live billing and the release/version, supplies any TCC/admin interaction through Jump Desktop, and owns money/customer-facing decisions.
- **Builder:** changes app/service code or checked-in configuration only when release-candidate checks expose drift; adds automated fail-closed checks where specified.
- **Vendor-ops:** verifies or configures Paddle through its API/runbook, without printing secret values; records IDs/statuses only in redacted evidence.
- **Lucius/UAT:** executes GUI, browser, clean-account, purchase, and distribution cases on Lucius' Mini or dispatches them to CI.
- **Project manager:** keeps 129 → 130 → 131 as the launch order while allowing A and B to execute in parallel, and confirms all release gates before C.

## User stories and acceptance criteria

### US-launch-readiness-1 — prove production trial-to-paid and portal management (Slice A / item 129)

*As a trial user, I want a live checkout that activates the plan I paid for and opens billing management without another sign-in, so that I can safely become a paying customer.*

#### Ownership boundary

**Builder (app/service code and checked-in configuration)**

- Confirm the production build resolves `PaddleConfig.active` to `.production`, includes three distinct live price IDs corresponding to `starter`, `pro`, and `unlimited`, and never falls back to sandbox when production configuration is incomplete.
- Confirm production `PADDLE_API_BASE` is `https://api.paddle.com`; the production Worker contains no item-123 sandbox lane/state; and release-candidate automated checks fail if a sandbox token, sandbox host, blank required value, duplicate price ID, or tier-matrix mismatch is detected.
- Preserve item 94's enforcement rule: trials are hard-enforced in code even while `ENFORCEMENT_MODE=soft` keeps paid tiers in measure-first soft mode. Do **not** globally set `ENFORCEMENT_MODE=hard` without a separate owner decision.
- Preserve item 91's per-click portal-session behavior and no-store response. A missing portal permission must produce observable failure/fallback evidence, never be reported as a successful portal-session test.
- If no drift is found, the builder produces evidence and makes no code change.

**Vendor-ops (Paddle API/runbook)**

- Verify the live catalog has exactly the launch products/prices in `docs/tier-matrix.md`: Starter $9/month, Pro $19/month, Unlimited $39/month, USD, IDs mapped to `starter`/`pro`/`unlimited`.
- Verify the live webhook endpoint targets the production Worker and subscribes to the required transaction/subscription lifecycle events.
- Verify a live API key exists with all required checkout/subscription permissions, including **`customer_portal_session.write`**. If not, prepare/mint the replacement through the approved vendor process and hand it to the Cloudflare secret-setting step without recording its value.
- Verify the live client-side token and approved checkout domain are production values. Record only redacted metadata, permission names, and resource IDs.

**Michael (dashboard/approval/money)**

- Give the exact written gate **production approved** before any live charge, production secret replacement, refund, or production release approval.
- Perform any Paddle dashboard-only action the API cannot perform and approve the real-dollar test purchase/refund disposition.
- No agent treats Paddle vendor verification from 2026-09-12 as authorization to spend money in this run.

**Cloudflare/production operations**

- Through the approved production deploy/secret workflow, verify required secrets are present and non-empty by exercising each code path, not by printing values: Paddle API, webhook verification, Clerk lookup, inference, and admin authorization.
- `ADMIN_TOKEN` must have real entropy and authenticate the admin path; evidence records pass/fail and length class only, never the token. Existing 2026-10-11 proof may be cited if the token has not rotated; any rotation requires re-verification.

#### Acceptance criteria

**AC-A1 — production configuration is internally consistent**
Given the signed release candidate and the production Worker revision, when the builder runs the configuration guards in CI, then the app selects Paddle production, the Worker selects `https://api.paddle.com`, each purchasable tier maps to one distinct live price matching the tier matrix, no sandbox credential/host is reachable from the production build, and the check exits non-zero for a blank, sandbox, duplicate, or mismatched fixture.

**AC-A2 — secrets and trial enforcement fail closed**
Given production with paid tiers in soft mode, when an authenticated trial account exceeds its trial cap, then `/v1/draft` returns the documented quota denial and `/v1/me` reports effective hard enforcement for that trial; when any required production secret is replaced by an empty test fixture in CI, then the affected request is rejected and no entitlement, checkout transaction, or admin response is granted.

**AC-A3 — live catalog and portal permission are verified without disclosure**
Given vendor-ops access to Paddle production, when it inspects the catalog, webhook, approved domain, client token metadata, and API-key permissions, then redacted evidence lists the three monthly USD prices, the production webhook URL/events, the approved `sentwise.ai` domain, and `customer_portal_session.write`; no key, token, webhook secret, card detail, or customer identifier appears in evidence.

**AC-A4 — a real-dollar trial converts and is tagged live (TC-74-08)**
Given Michael has written **production approved**, a controlled non-comp account is in an active no-card trial, its domain is not in `QA_EMAIL_DOMAINS`, and the signed production build runs on Lucius' Mini, when the tester buys Starter through the in-app live checkout for the displayed real dollar amount, then Paddle records a successful live transaction, the webhook attributes it to that account, the app changes from Trial to **Starter**, a managed draft succeeds under the paid entitlement, and `/admin/funnel` increments the live Starter activation population rather than `qa`. Evidence redacts the account, receipt, and payment method.

**AC-A5 — portal session is direct and fresh (TC-74-08)**
Given AC-A4's active subscription, when the tester chooses **Manage billing** twice, then each request returns a newly minted no-store portal-session link and the browser opens the subscribed account directly without asking for an email or magic link; the two links are not copied into evidence.

**AC-A6 — denied/failed purchase does not grant access**
Given Michael has not written **production approved**, when the run reaches the charge step, then the case is blocked before checkout submission and no charge occurs. Given a declined/abandoned payment or a failed webhook in a controlled negative test, when the app refreshes status, then it remains Trial/Expired as applicable, shows an actionable non-secret error, records no live paid activation, and does not unlock paid drafting.

### US-launch-readiness-2 — prove first value on a clean Mac (Slice B / item 130)

*As a first-time Mac user, I want to install Sentwise and reach an approved inbox reply and post-call follow-up without maintainer help, so that I can judge the trial before paying.*

All cases run in a **fresh macOS user account on Lucius' Mini** using a signed production artifact. A case may cite existing evidence only where the artifact and expected state are unchanged; the complete onboarding/value path must be captured in one run for item 130. Tests never run on Michael's machines. Use fixture mail/transcript content from `docs/qa/test-cases.md`, not customer content.

#### Predetermined test cases

| ID | Case and concrete expected result | Unhappy path | Evidence | Michael/TCC action |
|---|---|---|---|---|
| **TC-74-01** | In a clean user account, download the DMG in a browser, preserve quarantine, mount it, drag Sentwise to Applications, and launch. Gatekeeper identifies an Internet download, accepts the notarized Genkei Labs LLC app, and onboarding opens with no prior Sentwise state. | A malware/notarization block, unknown developer warning, crash, or stale onboarding state fails the case and prevents continuing with that artifact. | Video plus signature/notarization summary; no personal path. | Michael creates/authorizes the fresh macOS account if admin credentials are requested. Lucius' automation host needs Accessibility and Screen & System Audio Recording granted in that account through Jump Desktop. |
| **TC-74-02** | After removing the DMG-installed app without deleting unrelated files, `brew install --cask michaeltookes/tap/sentwise` installs the same advertised version and launches to first-run with no SHA or deprecated-syntax warning. | Any checksum, quarantine, dependency, cask-version, or deprecation warning is captured as friction and the case fails until filed/fixed. | Terminal screenshot and app version screenshot. | Same Lucius automation TCC grants as TC-74-01; no Sentwise-specific TCC expected. |
| **TC-74-03** | Complete onboarding with production Sentwise email-code sign-in, confirm the 14-day no-card Trial state, connect a Gmail fixture account using a valid app password, and reach the voice-learning step. Notification permission copy is understandable and **Allow** results in authorized notification state. | Invalid code, expired code, invalid/revoked app password, denied notifications, and offline service each show a specific recoverable message and never claim setup succeeded. Denying notifications leaves an in-app route to enable them later. | One continuous video with addresses/codes/passwords redacted. | Michael grants Notification permission for Sentwise through the visible macOS prompt if Lucius cannot drive that protected prompt; this is done in Jump Desktop. No credential is sent to the agent transcript. |
| **TC-74-04** | Learn a voice profile from the fixture Gmail Sent mailbox and finish onboarding. The completion state states that voice learning succeeded and persists after quit/relaunch. | An empty/too-small Sent mailbox or an offline inference request produces actionable copy and a retry path; onboarding does not silently mark voice learning complete. | Video and redacted profile/status screenshot. | No additional TCC. Mail and inference content remain in the app; evidence shows status only. |
| **TC-74-05** | Send the fixture inbound question, wait for the watcher, open the notification, draft the reply, provide fixture missing information if requested, approve in Review Drafts, and observe the configured send/save result in Gmail. | Offline drafting, a needs-info draft, or denied notification permission keeps the message reviewable and recoverable; no draft is sent or saved before explicit approval. | Video; subject/body and addresses redacted except approved fixture labels. | Notification prompt must already be granted from TC-74-03. Lucius' UI capture continues to require Accessibility/Screen Recording. |
| **TC-74-06** | Open **New Follow-up from Transcript…**, paste the approved fixture transcript, set fixture recipient/subject, generate, click the draft-ready notification's **Open** action, read the full draft in Review Drafts, and approve. The expected Gmail send/save result appears once. | Empty/unsupported transcript, inference offline, or notification dismissal shows a recoverable state; **Close** or dismissal never approves, sends, or saves the draft. | Continuous video from transcript input through Gmail result. | Notification TCC from TC-74-03; no microphone or screen-capture permission is required by Sentwise because this case pastes a transcript. |
| **TC-74-07** | Install the immediately previous signed version, choose **Check for Updates…**, confirm the dialog shows human release notes, update, relaunch, and verify the target version. The updated app remains notarized and existing clean-run state remains usable. | A blank notes panel, signature failure, downgrade prompt, lost account state, or failure to relaunch fails the case; the previous app remains usable if update validation fails. | Video plus appcast version/signature summary. | Lucius automation TCC only. No Michael machine or local private signing key is used. |

#### Acceptance criteria

**AC-B1 — both install paths pass**
Given the fresh Lucius account and the target signed artifact, when TC-74-01 and TC-74-02 run, then both installations produce the advertised app/version without notarization, checksum, cask, or stale-state errors.

**AC-B2 — the complete first-value loop passes**
Given the DMG-installed clean state, when TC-74-03 through TC-74-06 run in order, then the user starts a production trial, connects Gmail by app password, learns voice, approves one inbox reply and one transcript follow-up from the notification-to-Review-Drafts path, and neither message is dispatched before approval.

**AC-B3 — denial and recovery are observable**
Given notifications are denied or a network dependency is unavailable in a negative pass, when the user attempts the affected step, then Sentwise names the blocked dependency, preserves recoverable work, offers retry/settings guidance, and never reports a sent, saved, connected, learned, or paid state that did not occur.

**AC-B4 — update continuity passes**
Given the immediately previous signed version, when TC-74-07 runs, then Sparkle displays non-empty human notes, validates the signed update, installs the target version, and preserves the test user's configuration and pending local data.

**AC-B5 — every friction point becomes a stable backlog item**
Given any unexpected warning, extra unexplained step, inaccessible control, dead end, misleading copy, or failure in TC-74-01 through TC-74-07, when the run report is triaged, then item 130 remains open until each distinct confirmed friction has a new stable ID in `docs/backlog.md` (or a link to an exact existing item such as 109, 110, or 112–116), severity/priority, reproduction steps, expected/actual result, evidence path, mapped TC-74 case, and Given/When/Then fix criteria. Existing IDs are never duplicated or renumbered.

### US-launch-readiness-3 — ship and verify the launch release (Slice C / item 131)

*As a prospective customer, I want the public download, Homebrew cask, and automatic update to deliver the same trustworthy release with understandable notes and a reachable feedback address, so that I can install and get help confidently.*

#### Acceptance criteria

**AC-C1 — release gate and version are explicit**
Given items 129 and 130 are accepted and all launch-blocking defects are resolved, when Michael approves the customer-facing launch version and release, then the approved semantic version is used consistently in the project, CHANGELOG, tag, GitHub release, DMG, cask, and appcast. This work order specifies **1.0.0**; the contradictory 2026-10-22 recorded direction to remain on 0.x is an open owner decision below, so no final tag is cut until Michael resolves it.

**AC-C2 — `/release-prep` produces a human-readable release**
Given a human-written CHANGELOG section for the approved version, when `/release-prep` runs through the existing CI tag pipeline, then build/sign/notarize/staple/appcast/cask checks pass, the GitHub release notes summarize user-visible changes rather than commit titles, and the notes link directly to README **Quickstart** (item 71). Given a missing/empty CHANGELOG section, placeholder Sparkle key, signing failure, or notarization failure, the pipeline aborts before publishing a usable release.

**AC-C3 — public channels agree from a non-maintainer machine (TC-74-09)**
Given the release is published, when Lucius' Mini follows `sentwise.ai/download`, installs the Homebrew cask, and checks the appcast from the immediately previous release, then all three resolve to the same approved version/build, the DMG/cask checksum matches, the app is accepted by Gatekeeper, and the Sparkle dialog shows the same human notes. A mismatch blocks launch and the public link does not go out.

**AC-C4 — support and update trust are live**
Given the release candidate, when the tester uses **Report a Problem…** with a redacted diagnostic fixture, then the composer targets `feedback@sentwise.ai` and a monitored inbox receives the message within the existing QA case's one-hour window. When release operations compare `SUPublicEDKey` in the built app with the public key derived from the offline private key, then they match exactly; evidence records only the public-key fingerprint/match result and confirms the private key was not copied to the repo or QA machine.

**AC-C5 — release checklist is the system of record**
Given Slice C work begins, when each gate is completed, then the existing `docs/launch-checklist.md` is updated with date, artifact/version, and redacted evidence reference for the corresponding box. A box is not checked from code review alone when its wording requires live or non-maintainer verification. Item 131 closes after the release checks pass; umbrella item 74 closes only after the owner-approved public link goes out.

**AC-C6 — failed release remains private and recoverable**
Given any channel serves the wrong build, support mail does not arrive, Sparkle signature validation fails, or an unresolved P1/P2 launch defect exists, when the release gate is reviewed, then the announcement/public-link step is blocked, the last known-good release remains available, and a stable backlog defect is filed with the failed TC-74 case and evidence.

## UX review

This brief introduces no new screen. It verifies the existing onboarding, Subscription, notification, Review Drafts, checkout, update, and feedback experiences. The UX contract for the launch run is:

- **State is explicit:** Trial, checkout loading, payment failure, paid plan, portal loading/failure, offline, voice-learning failure, Needs your input, and notification denial must be distinguishable without logs.
- **Approval stays deliberate:** notification actions are **Open** and **Close** only. The full draft is read and approved in Review Drafts; closing/dismissing cannot send or save.
- **Money copy is concrete:** checkout shows plan name, USD monthly amount, and no-card trial status before submission. After successful webhook reconciliation the app says **You're on Starter** (or the purchased tier). It never says paid on client-side checkout completion alone.
- **Recovery is adjacent to the failure:** invalid code/app password offers retry; denied notifications point to System Settings; offline draft/voice work remains retryable; portal failure stays in Subscription and never opens a misleading signed-out success page.
- **Accessibility:** all controls used by TC-74 cases must be discoverable by accessible name/identifier, keyboard reachable, and expose disabled/loading state. A control Lucius cannot identify becomes a friction item rather than a coordinate-only launch workaround.
- **Sensitive evidence:** screenshots and video obscure email addresses, sign-in codes, app passwords, transaction/customer IDs, card details, and message/transcript text except approved synthetic fixture labels.

## Constraints

- **Billing:** no live charge, refund, API-key replacement, or production release without Michael's approval. Paddle remains merchant of record. Launch tiers and prices are Starter $9, Pro $19, Unlimited $39 monthly unless Michael records a new decision.
- **Tier gating:** the paid proof uses Starter and must not accidentally unlock Pro/Unlimited account limits. Trial effective enforcement remains hard; paid-tier enforcement remains soft until a separate owner decision.
- **Platform:** native macOS 14+ signed/notarized app. Clean-machine tests run only on Lucius' Mini or CI.
- **Auth/mail:** production Sentwise account auth and Gmail app-password connection are the required launch path. Gmail OAuth/CASA item 104 is not a dependency.
- **Local-first/privacy:** mail, voice profile, transcript, drafts, and app password remain local except the content sent for a managed drafting request through the stateless proxy. No request/response body is retained or logged by Sentwise.
- **Offline:** install/update metadata can be inspected offline, but sign-in, Gmail connection, managed drafting, live checkout, portal creation, and webhook reconciliation require network access; each must fail recoverably.
- **Release:** current source says 1.0.0 was previously cut, yanked before announcement, and replaced by 0.2.0. Reusing a deleted semantic version may confuse update/release history; the owner must settle the launch version before tagging.
- **Evidence:** use synthetic fixture content and controlled company QA accounts. Do not put customer data, secrets, raw payment details, or personal filesystem paths in docs or artifacts.

## Data and privacy notes

| Data | Leaves the Mac? | Stored where | Evidence/consent requirement |
|---|---|---|---|
| Gmail app password and Clerk session | Used directly for provider/auth calls; never sent to analytics | macOS Keychain | Never print or record; evidence shows only successful/failed state. |
| Voice samples, inbox thread, transcript, and generated draft | Sent only when needed to the managed inference proxy/model; no Sentwise body logging or retention | Source content and resulting local profile/drafts remain on device | Existing onboarding privacy copy must remain accurate; recordings obscure fixture text. |
| Paddle checkout/payment data | Sent to Paddle in its checkout surface | Paddle as merchant of record | Sentwise evidence records plan/amount/status only; no card, receipt, customer, transaction, or portal URL. |
| Subscription and trial state | Sentwise service necessarily stores entitlement metadata | Clerk/Paddle/service state as already documented | Required to provide trial/billing; no new consent prompt introduced. |
| Funnel population | Server writes pseudonymized billing/licensing events tagged `qa` or `live` | Analytics Engine | No mail/content/email stored in the event. AC-A4 proves a controlled non-QA purchase lands only in `live`. |
| Clean-run screenshots/video | QA artifact store | Lucius/QA evidence location | Redact credentials, addresses, payment identifiers, mail, transcript, and personal paths before retention. |
| Feedback diagnostic fixture | Mail to monitored `feedback@sentwise.ai` | Support mailbox per existing policy | Use synthetic fixture and verify redaction before sending. |

Required consent/copy remains the existing product promise: Sentwise reads local mail to find reply-worthy messages and sends mail/thread, voice-learning samples, or transcript content to the drafting service only when that workflow needs drafting/learning; Sentwise does not store request/response bodies or use them for training. Do not claim that nothing leaves the device or that the model provider offers zero retention.

## Open questions and working assumptions

1. **Which version is the public launch?** This work order says **1.0.0**, but the 2026-10-22 recorded owner decision says it will be some time before 1.0.0 and directs pre-launch work into 0.2.3; `docs/launch-checklist.md` also records the earlier 1.0.0 as yanked. **Assumption:** prepare Slice C for 1.0.0 as ordered here, but do not create the tag/release until Michael explicitly confirms that this work order supersedes the 0.x decision.
2. **Authorize the real-dollar production purchase and its disposition.** **Assumption:** use one controlled non-comp account to buy Starter at $9 after Michael writes **production approved**; Michael decides whether it remains active or is refunded/canceled after portal verification. No charge occurs before that approval.
3. **Are existing 2026-09/10 production checks fresh enough?** The live Paddle catalog, secret hygiene, feedback mailbox, and keypair match are documented complete, but the paid portal path has never had a real production subscriber. **Assumption:** cite unchanged setup checks, rerun non-secret drift checks against the release candidate, and require new AC-A4/A5 evidence rather than repeating dashboard work that has not changed.

## Out of scope

- Public marketing copy, launch posts, ICP outreach, or the `icp-finder` run itself.
- A new billing QA architecture; item 123 owns the isolated sandbox deployment and recurring no-money purchase testing.
- Production Google OAuth callback enablement (item 121) except as an independently tracked release prerequisite chosen by the project manager.
- Changes to trial duration, tier prices, quota quantities, refund policy, or paid-tier enforcement.
- Legal-policy revision, third-party security review, App Store distribution, Windows, or mobile.

## Traceability

| Story | Slice/backlog | Test case(s) | Existing dependencies/evidence |
|---|---:|---|---|
| US-launch-readiness-1 | 129 | TC-74-08 | 56 checkout/licensing; 91 portal sessions; 94 trial enforcement; 123 recurring sandbox lane; `docs/launch-checklist.md` §§2–3 |
| US-launch-readiness-2 | 130 | TC-74-01 through TC-74-07 | 71 quickstart; 95 checkout hardening; 96 purge/erase; existing TC-M1-01/02/07/08; item 74 §6 |
| US-launch-readiness-3 | 131 | TC-74-09 plus TC-74-07 update leg | 71 quickstart; item 114 release notes; `docs/releasing.md`; `docs/launch-checklist.md` §§4–7 |

The project planner may mirror these cases into `docs/qa/test-cases.md` without changing their IDs or outcomes. If a TC-74 case discovers friction, the resulting backlog item's trace must point back to that exact case.
