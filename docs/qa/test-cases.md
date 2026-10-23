# Sentwise — test cases

Predetermined cases for the milestones in `docs/plan.md`, written before the code. QA runs them verbatim; IDs `TC-M<n>-<nn>` never change once published. A case that a build cannot pass is a defect or a backlog item, never an edited case. Where a case quotes UI text or an endpoint for work not yet built (items 87, 88, 92, 113, 118, 119, 123, 124), the quoted text is the spec the builder implements.

## Preamble

**Where QA runs.** Everything runs on Lucius' Mac Mini (the Agent Mini), never on the maintainer's MacBook.
- `executor: lucius` cases drive the installed, signed Sentwise app in `/Applications` with Peekaboo and capture with screen recording (`screencapture -V`) or screenshots.
- `executor: uat` cases drive a browser with Playwright or call HTTP endpoints, also on the Mini.

**Relation to the daily pass.** Lucius already runs a daily QA pass from `SENTWISE_QA.md` in his workspace (settings sweep, install-path checks, the status-menu recipe, a read of the Subscription pane). That pass is regression monitoring and keeps running. These cases are milestone acceptance: run each milestone's cases once against the release that milestone ships, and re-run only the affected cases after a fix.

**Assets.** `screenshot` means one per step; the last one is the evidence. `video` means one recording of the whole case. Redact codes, tokens, and any mailbox content that is not the fixture's own. Reports go to `docs/qa/runs/<date>-<milestone>/report.md` on a `qa/<date>-<milestone>` branch; videos stay local and are linked by path.

**Fixtures** (no seed database; these are the fixtures):
- **F1, the standing QA account:** `luciusfox@prowlqa.dev`. The same address is the connected Gmail (Google Workspace on the `prowlqa.dev` domain) and the Sentwise account, which carries a comped **Pro** plan (item 111), so the Subscription pane reads Pro, active. Credentials live in Lucius' workspace secrets and the password manager, never in this repo. Every case that signs the app into another account ends by signing back in as F1.
- **F2, a throwaway trial account:** `luciusfox+trial-<RUNID>@prowlqa.dev`, where `<RUNID>` is unique per run: the run's date and time, `YYYYMMDD-HHMM` (for example `20261020-1430`), never the date alone. Same-day reruns must not collide, because a purchaser from TC-M3-05 is kept until its cancellation takes effect. Sentwise sign-in codes for F2 arrive in F1's Gmail inbox (plus addressing). F2 is created inside the case by signing in, and removed in teardown. Record the RUNID in the run report.
- **F3, the sandbox purchaser:** `luciusfox+sbx-<RUNID>@prowlqa.dev`, same RUNID rule as F2. F3 exists only in the Clerk **development instance** behind the sandbox deployment (item 123); it is created by signing in to the **Sentwise QA** build, and its sign-in codes also arrive in F1's Gmail inbox. It never exists on production. Remove it from the Clerk development instance in teardown; nothing about it needs a refund.
- **S1, an outside sender:** a mailbox QA controls on a domain other than `prowlqa.dev` (the wave-2 test mailbox, genkei-ops P1-3). Until it exists, the orchestrator asks Michael to send the message from his own address at the marked step. S1 only sends the fixture question below; it never receives anything from Sentwise.
- **Q1, the fixture inbound question** (subject `Pilot kickoff`, body `Hi Lucius, can you confirm Thursday at 10am works for the pilot kickoff? Thanks, Dana`).
- **A1, the fixture availability** that answers Q1: `Yes, Thursday at 10am works for me.` Nothing in the mailbox tells Sentwise this, so a correct build may ask for it (a **Needs your input** card with no **Approve** button) instead of guessing.
- **T1, the fixture transcript.** Paste exactly:
  ```
  Dana (Acme): Thanks for walking us through the pilot today.
  Lucius: Happy to. To recap, you want 10 seats for a 30-day pilot starting November 2.
  Dana (Acme): Right. I need the security questionnaire back by Friday.
  Lucius: I'll send it Thursday, along with the pilot order form.
  Dana (Acme): Great. Let's meet again on November 9 to review results.
  ```
- **Mail safety:** every draft is addressed only to `luciusfox@prowlqa.dev`, and send behavior is **Save as draft**. No case sends mail to anyone else.
- **Admin endpoints:** `uat` reads `SENTWISE_ADMIN_TOKEN` from its run environment on the Mini (provisioned by Michael). The token never appears in a step, a log, or an asset; screenshots of requests show the header as `Bearer ***`. Worker base URL (`{base}`): `https://sentwise-inference.sentwise-service.workers.dev`.
- **Sandbox deployment (item 123):** the Worker `sentwise-inference-sandbox`; its hostname (`{sandbox}`) is recorded in `docs/billing-qa.md`. Admin calls to it use `SENTWISE_SANDBOX_ADMIN_TOKEN`, and the sandbox Paddle API calls in TC-M3-10 use `PADDLE_SANDBOX_API_KEY`, both from `uat`'s run environment on the Mini, with the same redaction rule. It runs the same sentwise-service revision as production; the run report records the deployed-revision fields in TC-M3-05's preconditions (plan.md, Risks, lockstep rule), and a mismatch with the commit under test stops the M3 run.
- **The two apps:** the production build is **Sentwise** in `/Applications/Sentwise.app` (status item "Sentwise"); the QA build is **Sentwise QA** in `/Applications/Sentwise QA.app` (status item "Sentwise QA"), built from the same release tag and pointed at `{sandbox}`. Only one runs at a time: quit one with its **Quit** menu item before launching the other. Every step runs in the app the case's preconditions name; a case that names neither means the production build. The production fallback sequence under TC-M3-05 overrides this to **Sentwise** for the cases it lists.
- **Opening the status menu:** on 0.2.1 and later, click the menu-bar status item whose accessibility label is "Sentwise" (identifier `sentwise.statusItem`, item 112). Settings opens from the status menu item **Settings…**; its tabs are General, Account, AI, Subscription, Analytics, Rules, About.
- **Opening the status menu on 0.2.0 (old-build fallback):** 0.2.0 labels only the menu-bar image, so on macOS 26 its item has no name in the accessibility tree and Peekaboo cannot find it by "Sentwise" (`docs/resolved.md`, item 112). On 0.2.0, use the coordinate-click status-menu recipe from `SENTWISE_QA.md` in Lucius' workspace: locate the `envelope.badge` icon in a menu-bar screenshot and click its coordinates. Before acting on the menu, confirm it contains **Check for Updates…** and **Quit Sentwise**. If it does not, press Escape and do not click anything in it, because a neighboring unnamed icon was opened. If the recipe fails twice, the orchestrator asks Michael for one human-assisted click on the Mini (screen sharing) to open the menu, and the report records that the first click was assisted. This fallback is only for 0.2.0; on 0.2.1+ a coordinate click is a TC-M1-03 failure.
- **Funnel populations:** `GET /admin/funnel` splits every counter by account population (items 88, 118). The top-level counters are the **live** population: accounts whose email domain is not in the Worker's `QA_EMAIL_DOMAINS` (initially `prowlqa.dev`). The `qa` object holds the same counters for QA-domain accounts on production. Every fixture account on production (F1, F2) is in the QA population, so its trials, checkouts, and cancellations land only in `qa.*`. Sandbox events never reach the production funnel, because they never reach the production Worker: the sandbox deployment writes to its own dataset, read at `{sandbox}/admin/funnel` with the same shape (F3 lands in its `qa.*`). A funnel assertion always compares numerator and denominator within one population.
- **Throwing a draft away:** a normally generated draft in Review Drafts has **Deny** and **Approve** (**Discard** appears only in exceptional states such as a dispatch queued offline). To throw a draft away, click **Deny**; in the "Why deny this draft?" sheet select **Not worth replying** and click **Deny** in the sheet. If "Don't ask again this session" was ticked earlier in this app run, the sheet does not appear and the draft is removed directly; either way the draft leaves the list.

## Launch readiness — item 74

### TC-74-08 Production trial converts to Starter and opens fresh portal sessions
- **Executor:** lucius (app and Paddle-hosted checkout/portal) and uat (redacted admin/config assertions)
- **Verifies:** item 129; AC-A1 through AC-A6 in `docs/requirements/launch-readiness.md`
- **Preconditions:**
  - Michael has written the exact approval **production approved** for this run. Without it, stop before checkout submission; no charge, production secret replacement, refund, or release is authorized by this case.
  - A signed/notarized production release candidate is installed as **Sentwise** on Lucius' Mini. Its CI configuration guards pass: the production bundle resolves `PaddleConfig.active` to the approved live config; Starter, Pro, and Unlimited have three distinct approved price IDs corresponding to $9/$19/$39 monthly USD; invalid blank, sandbox, duplicate, or tier-swapped fixtures disable checkout with an actionable configuration error.
  - The production Worker revision under test matches the release candidate's expected service revision. Its checked-in production config uses `PADDLE_API_BASE=https://api.paddle.com`, paid tiers remain `ENFORCEMENT_MODE=soft`, and automated coverage proves trials resolve to effective hard enforcement. The item-123 sandbox deployment and credentials are not used.
  - Vendor-ops has recorded current redacted evidence that the live catalog, `sentwise.ai` approved domain, production webhook/events, live client-token metadata, and API-key permissions (including `customer_portal_session.write`) match the launch requirements. No credential value or portal URL enters the report.
  - A fresh controlled production account is in an active no-card trial, is not comped, and uses an email domain that is **not** in `QA_EMAIL_DOMAINS`. Its credentials and sign-in code are available only in Lucius' secret store. Record redacted pre-run `/admin/funnel` live and `qa` baselines for Starter activations.
  - Michael supplies the approved real payment method through Jump Desktop if protected entry is required and decides the post-test refund/cancellation disposition. No agent records card, receipt, transaction, customer, or subscription identifiers.
- **Steps:**
  1. In **Sentwise**, sign in as the controlled trial account and confirm Subscription shows an active Trial. Open the Starter checkout and confirm it displays **Starter** at **$9.00/month USD** with no sandbox/test marking.
  2. Reconfirm the written **production approved** gate in the run record, then submit the approved real-dollar payment. If the gate is absent, abandon the checkout and mark the case blocked with no charge.
  3. Wait for webhook reconciliation, close and reopen **Settings…** → **Subscription**, and confirm the plan changes from Trial to **Starter**. A declined/abandoned payment or failed webhook must leave Trial/Expired unchanged and show an actionable error; it must not unlock paid access.
  4. Create one managed follow-up from T1, wait for the draft, then throw it away with **Deny**. Confirm drafting succeeds under the paid Starter entitlement.
  5. uat reads the redacted production `/admin/funnel` result for the run window. Compare it with the pre-run baseline without printing the account or bearer token.
  6. Choose **Manage billing** and confirm the browser opens the subscribed Paddle account directly without an email or magic-link prompt. Close the portal, return to Sentwise, choose **Manage billing** again, and confirm the second direct portal session also opens. Do not copy either URL into evidence.
- **Expected:** Paddle records one successful live Starter transaction; Sentwise reports Starter only after webhook reconciliation; the managed draft succeeds; live `subscriptionsActivated.starter` increases by one while `qa.subscriptionsActivated.starter` does not change; both Manage billing actions mint separate no-store authenticated portal sessions. Any payment denial, webhook failure, missing portal permission, blank secret, sandbox/mismatched config, signed-out portal, or false paid entitlement fails the case and blocks launch.
- **Asset:** one redacted video covering the app state transitions and two portal opens, plus redacted screenshots of the $9 Starter checkout, final Starter state, and live-vs-qa funnel deltas. Never capture credentials, payment details, identifiers, receipt, or portal URLs.
- **Teardown:** follow Michael's recorded keep/cancel/refund decision through the separately approved production process; restore Sentwise to F1 only after evidence is complete. Teardown is not authorization to issue a refund or alter production state.

## M1 v0.2.1 ships

### TC-M1-01 Sparkle update shows release notes
- **Executor:** lucius
- **Verifies:** items 114, 117
- **Preconditions:** Sentwise 0.2.0 (build 5) installed in `/Applications` and running, signed in as F1; v0.2.1 published (GitHub release, appcast, cask).
- **Steps:**
  1. Open the status menu with the **old-build fallback** from the preamble (0.2.0 has no accessibility name; do not search for "Sentwise"), confirm it lists **Check for Updates…** and **Quit Sentwise**, and click **Check for Updates…**.
  2. Wait for the update dialog.
  3. Scroll the release-notes area to the bottom.
- **Expected:** the dialog reads "Sentwise 0.2.1 is now available" and its release-notes area shows the 0.2.1 CHANGELOG section with at least one heading and one bullet; it is not blank. The report says whether step 1 used the coordinate recipe or a human-assisted click.
- **Asset:** video

### TC-M1-02 Install the update and confirm the version
- **Executor:** lucius
- **Verifies:** item 117
- **Preconditions:** TC-M1-01 passed, dialog open.
- **Steps:**
  1. Click **Install Update**, then **Install and Relaunch** when offered.
  2. After relaunch, open **Settings…** → **About**.
- **Expected:** About shows version 0.2.1 with a build number higher than 5; the Subscription tab still shows Pro for F1 (no sign-out, no Keychain password prompt during or after the update).
- **Asset:** screenshot

### TC-M1-03 Status item is found by name
- **Executor:** lucius
- **Verifies:** item 112
- **Preconditions:** Sentwise 0.2.1 running.
- **Steps:**
  1. With Peekaboo, list menu-bar items and find the one labeled "Sentwise".
  2. Click it.
- **Expected:** Peekaboo finds the item by the label "Sentwise" without coordinates, and the menu that opens contains **New Follow-up from Transcript…**, **Browse Mailbox…**, **Setup Assistant…**, **Settings…**, **Activity History…**, **Report a Problem…**, **Launch at Login**, **Check for Updates…** (not "Unavailable"), and **Quit Sentwise**.
- **Asset:** screenshot

### TC-M1-04 Launch at login explains macOS approval
- **Executor:** lucius
- **Verifies:** item 113
- **Preconditions:** Sentwise 0.2.1 running. In System Settings → General → Login Items & Extensions, Sentwise is present and switched **off** (the state that makes registration return "requires approval").
- **Steps:**
  1. Open **Settings…** → **General**.
  2. Turn on **Launch at login**.
  3. Wait 3 seconds.
  4. Click **Open Login Items Settings**.
- **Expected:** after step 3 the toggle is still on and a caption under it reads "macOS needs your approval to open Sentwise at login." with a button **Open Login Items Settings**; step 4 opens System Settings at Login Items & Extensions.
- **Asset:** video

### TC-M1-05 Status menu mirrors the approval state
- **Executor:** lucius
- **Verifies:** item 113
- **Preconditions:** TC-M1-04 state (approval still pending).
- **Steps:**
  1. Open the status menu.
  2. Hover **Launch at Login**.
- **Expected:** **Launch at Login** carries a mixed-state or warning mark and its tooltip or subtitle says macOS approval is needed; it does not show a plain checkmark.
- **Asset:** screenshot

### TC-M1-06 Launch at login turns on once approved
- **Executor:** lucius
- **Verifies:** item 113
- **Preconditions:** TC-M1-05 done.
- **Steps:**
  1. In System Settings → Login Items & Extensions, switch Sentwise **on**.
  2. Return to **Settings…** → **General**.
- **Expected:** the toggle is on with no caption, and the status-menu **Launch at Login** item shows a plain checkmark.
- **Asset:** screenshot

### TC-M1-07 Homebrew install has no deprecation warning
- **Executor:** lucius
- **Verifies:** item 116
- **Preconditions:** v0.2.1 cask published in `michaeltookes/tap`; Sentwise quit; Terminal open on the Mini.
- **Steps:**
  1. Run `brew update`.
  2. Run `brew reinstall --cask michaeltookes/tap/sentwise`.
- **Expected:** the command exits 0, installs version 0.2.1, and prints no line containing "deprecated".
- **Asset:** screenshot (terminal)

### TC-M1-08 Onboarding leg on a clean path: Setup Assistant, first follow-up, first inbox draft
- **Executor:** lucius (Michael sends Q1 at step 10 if S1 does not exist yet)
- **Verifies:** item 74 (`docs/launch-checklist.md` §6, first-run onboarding box)
- **Preconditions:**
  - Sentwise 0.2.1 running as F1 with F1's mailbox connected.
  - The persisted onboarding flag is **false**. The menu item **Setup Assistant…** opens the wizard whether or not onboarding was completed, so the wizard opening proves nothing. Check the flag in the file instead:
    - With Sentwise quit, run in Terminal `plutil -extract onboardingCompleted raw -o - ~/Library/Application\ Support/Sentwise/Settings.json`. This is `Settings.onboardingCompleted`, which `PersistenceService` writes to `Settings.json`.
    - The output `false` means the flag is false. An error that the key does not exist means the same, because the app decodes a missing key as false. Then relaunch Sentwise, quit it again, and re-read the flag: at launch `reconcileOnboardingState()` marks an already-configured older install as completed. Proceed in F1's user only if the flag still reads false.
  - If the flag reads `true`, run the whole case in the freshly reset `sentwise-stranger` macOS user from TC-M5-01. There, `Settings.json` is absent, so the flag is false, and the user has no mailbox credentials and no Sentwise session, so step 1 connects both (its fallback branch). Do not edit `Settings.json` by hand to reset the flag.
  - Notifications are allowed for Sentwise.
  - Both branches sign in to Sentwise AI as a **fresh F2** (preamble: `luciusfox+trial-<RUNID>@prowlqa.dev`, new RUNID for this run, a trial account, never comped), not F1, so the case exercises the trial sign-in and entitlement path launch-checklist §6 requires. F1's Gmail stays the connected mailbox. Record the RUNID in the report. In F1's user, before step 1 (after the flag check), sign F1 out of Sentwise AI: **Settings…** → **Subscription** → **Sign out**; leave the mailbox connected.
- **Steps:**
  1. Status menu → **Setup Assistant…** (in the stranger-user fallback it opens by itself at first launch). Walk the steps with **Continue**:
     - F1's user: the mailbox step shows "Connected as luciusfox@prowlqa.dev"; **Continue**. On the Sentwise AI step, sign in as the fresh F2: click **Use Sentwise AI** if it is shown, enter F2 in **Email address**, click **Send sign-in code**, read the code from F1's Gmail inbox (plus addressing), enter it in **6-digit code**, click **Verify & connect**, and wait for "Connected as" F2; then **Continue**.
     - Stranger-user fallback: on the mailbox step, enter `luciusfox@prowlqa.dev` in **Email address** and F1's Gmail app password (Lucius' workspace secrets) in **App password**, click **Test Connection**, and wait for "Connected as luciusfox@prowlqa.dev"; then **Continue**. On the Sentwise AI step, sign in as the fresh F2 exactly as in F1's user above. **Continue** stays disabled on each step until its connection is made.
  2. On the send-behavior step choose **Save as draft**, then **Continue**.
  3. On the voice step click **Learn my voice** and wait until it finishes.
  4. Click **Finish**.
  5. Quit Sentwise (**Quit Sentwise**) and relaunch it from `/Applications`.
  6. Status menu → **New Follow-up from Transcript…**. In **Recipients** enter `luciusfox@prowlqa.dev`; in **Subject** enter `Pilot next steps`.
  7. Paste T1 into the transcript area and click **Draft follow-up**.
  8. When the draft-ready notification appears, click it (or click **Open Review Drafts**). In Review Drafts, expand the draft and click **Approve**. This first draft started F2's trial (both branches), so then close the Settings window if it is open, open **Settings…** → **Subscription** (this refreshes status, as in TC-M2-06 step 7), and read the plan line.
  9. If the status menu shows **Start Watching**, click it; it must then read **Pause Watching**.
  10. From S1, send Q1 to `luciusfox@prowlqa.dev`.
  11. Wait up to 10 minutes for the notification "Reply-worthy: <S1 sender> — draft a reply?", then click it.
  12. On the Reply-worthy card in Review Drafts, click **Draft reply** and wait for the draft.
  13. If the card shows **Needs your input** with the column "Answer to re-draft" and no **Approve** button: type A1 into the **Your answer** field under the question about Thursday or availability (leave any other answer fields empty), click **Re-draft with my answers**, and wait for the card to change to "Proposed reply". If the card already shows "Proposed reply", go on.
  14. Click **Approve**.
  15. In Gmail on the Mini, open Drafts for `luciusfox@prowlqa.dev`.
- **Expected:**
  - After step 5 the Setup Assistant does not reopen by itself. With Sentwise quit, the `plutil` command from the preconditions prints `true` (onboarding completed and persisted; capture the terminal).
  - The report records which macOS user ran the case and the flag value before step 1.
  - Gmail Drafts holds the follow-up "Pilot next steps", addressed only to `luciusfox@prowlqa.dev`. It mentions the security questionnaire by Friday and the November 9 meeting.
  - Gmail Drafts also holds a reply in the "Pilot kickoff" thread that confirms Thursday at 10am works. A reply that confirms the time without step 13 having supplied A1 is a defect (an invented user decision), not a pass.
  - The report records whether step 13 was needed.
  - Both branches: step 8's plan line reads "Trial — 14 days left" for F2 (trial entitlement, not Pro and not a comp), and drafting in steps 7 and 12 was never blocked by a subscribe prompt. A Pro, comped, or "Trial ended" plan line fails the case.
  - Nothing was sent.
  - This case passing ticks the §6 onboarding box.
  - Teardown (both branches): **Settings…** → **Subscription** → **Sign out** of F2; the orchestrator deletes F2 from production. In F1's user, then sign back in as F1 and confirm the Subscription tab reads Pro.
- **Asset:** video

### TC-M1-09 Live tests leave the installed app alone
- **Executor:** lucius
- **Verifies:** item 115 (regression on the v0.2.1 runner)
- **Preconditions:** Sentwise 0.2.1 quit by Lucius (the workflow refuses to run while it is open); the orchestrator dispatches `live-tests.yml` on `main`.
- **Steps:**
  1. Wait for the workflow run to finish; open its summary.
  2. Launch Sentwise from `/Applications`.
- **Expected:** the run's keychain tripwire step passes, and Sentwise launches to the menu bar signed in as F1 with no Keychain password prompt.
- **Asset:** screenshot

### TC-M1-10 Release page and changelog
- **Executor:** uat
- **Verifies:** item 117
- **Preconditions:** v0.2.1 published.
- **Steps:**
  1. Open `https://github.com/michaeltookes/sentwise/releases/tag/v0.2.1`.
  2. Open `https://github.com/michaeltookes/sentwise/blob/main/CHANGELOG.md`.
  3. Open `https://sentwise.ai/download` and record the final redirect URL.
- **Expected:** the release has a `.dmg` asset and notes linking the README quickstart; CHANGELOG has a `## [0.2.1]` section dated on the release day; `/download` ends at the v0.2.1 DMG.
- **Asset:** screenshot

## M2 Funnel is measurable

### TC-M2-01 Changelog page lists releases
- **Executor:** uat
- **Verifies:** sentwise-landing-page item 10 (genkei-ops 6c-1)
- **Preconditions:** site deployed to production.
- **Steps:**
  1. Open `https://sentwise.ai/changelog`.
- **Expected:** the page heading is "Changelog"; entries appear newest first, the first is "0.2.1" with its date and the second is "0.2.0"; each entry has at least one bullet; HTTP status 200.
- **Asset:** screenshot

### TC-M2-02 Changelog is reachable and indexed
- **Executor:** uat
- **Verifies:** sentwise-landing-page item 10
- **Preconditions:** as TC-M2-01.
- **Steps:**
  1. Open `https://sentwise.ai/`, scroll to the footer, click **Changelog**.
  2. Open `https://sentwise.ai/sitemap.xml`.
- **Expected:** step 1 lands on `/changelog`; the sitemap contains `https://sentwise.ai/changelog`.
- **Asset:** screenshot

### TC-M2-03 Pricing cards match the tier matrix
- **Executor:** uat
- **Verifies:** sentwise-landing-page item 14 (genkei-ops 6c-2)
- **Preconditions:** site deployed.
- **Steps:**
  1. Open `https://sentwise.ai/pricing`.
  2. Read each card.
- **Expected:** Starter ($9) says 1 connected email account and no background inbox watching; Pro ($19) says 2 connected email accounts and inbox watching with reply-worthy notifications; Unlimited ($39) says up to 5 connected email accounts; the page contains no "coming soon", "Zoom", "Teams", "CRM", or "Slack".
- **Asset:** screenshot

### TC-M2-04 Page views are recorded
- **Executor:** uat
- **Verifies:** genkei-ops P1-2 (site funnel stage)
- **Preconditions:** site deployed; Playwright records network requests.
- **Steps:**
  1. Open `https://sentwise.ai/`.
  2. Click **Pricing** in the nav.
- **Expected:** a request to a path under `/_vercel/insights/` completes with status 2xx for each of the two page loads.
- **Asset:** screenshot (network log)

### TC-M2-05 Funnel endpoint requires the admin token
- **Executor:** uat
- **Verifies:** items 88, 118
- **Preconditions:** Worker deployed with item 88/118.
- **Steps:**
  1. `GET {base}/admin/funnel?from=2026-10-01&to=2026-10-31` with no `Authorization` header.
  2. Repeat with `Authorization: Bearer wrong`.
- **Expected:** both return 401 with no counts in the body.
- **Asset:** screenshot (responses)

### TC-M2-06 A new trial is counted
- **Executor:** uat (steps 1 and 8) and lucius (steps 2–7)
- **Verifies:** item 88
- **Preconditions:** Sentwise running as F1; `uat` has the admin token. The trial starts on the account's first authenticated draft, not at sign-in (`docs/managed-inference.md`); `/v1/me` only reads trial state.
- **Steps:**
  1. uat: `GET {base}/admin/funnel?from=<today>&to=<today>` with the token; note `qa.trialsStarted` and the live `trialsStarted`.
  2. lucius: **Settings…** → **Subscription** → **Sign out**.
  3. Click **Sign in or create your account**, enter F2 in **Email address**, continue.
  4. Read the code from F1's Gmail inbox, enter it in **6-digit code**, verify.
  5. From the status menu open **New Follow-up from Transcript…**, enter recipient `luciusfox@prowlqa.dev`, paste T1, click **Draft follow-up**, and wait for the draft (this first draft starts the trial).
  6. In Review Drafts, throw the draft away with **Deny** as in the preamble ("Throwing a draft away": **Deny**, select **Not worth replying**, **Deny** in the sheet).
  7. Close the Settings window, reopen **Settings…** → **Subscription** (this refreshes status), and read the plan line.
  8. uat: repeat step 1.
- **Expected:** step 7 shows "Trial — 14 days left", and `qa.trialsStarted` in step 8 is exactly one higher than in step 1 (F2 is a QA-domain account). The live `trialsStarted` is recorded in the report but not asserted, because real users can start trials during the window; that QA trials never reach it is covered by item 88's unit test. Keep F2 signed in for TC-M2-07.
- **Asset:** video

### TC-M2-07 Opening checkout is counted
- **Executor:** uat (steps 1 and 6) and lucius (steps 2–5)
- **Verifies:** item 118
- **Preconditions:** TC-M2-06 done, F2 signed in on trial; `uat` has the admin token.
- **Steps:**
  1. uat: `GET {base}/admin/funnel?from=<today>&to=<today>` with the token; record `qa.checkoutsOpened.starter` and `qa.subscriptionsActivated.starter` as this case's baselines.
  2. lucius: **Settings…** → **Subscription** → **Subscribe**.
  3. In "Choose your plan", click the Starter card.
  4. Wait until the Paddle checkout form ("Secure checkout by Paddle") renders.
  5. Click **Close**. Then **Sign out**, and sign back in as F1.
  6. uat: repeat step 1.
- **Expected:** `qa.checkoutsOpened.starter` in step 6 is at least one higher than in step 1 (F2 is new this run, so this is its first Starter checkout; the counter counts unique accounts, so reopening the Starter checkout as F2 would not raise it again), and `qa.subscriptionsActivated.starter` in step 6 equals step 1; no purchase was made. The production build always opens the live Paddle checkout; checkouts opened from the Sentwise QA build reach only the sandbox deployment and never appear in this endpoint.
- **Asset:** video

### TC-M2-08 Funnel response shape
- **Executor:** uat
- **Verifies:** items 88, 118
- **Preconditions:** token available.
- **Steps:**
  1. `GET {base}/admin/funnel?from=2026-10-01&to=2026-10-31` with the token.
- **Expected:** 200 JSON with numeric fields `trialsStarted`, `checkoutsOpened.starter`, `.pro`, `.unlimited`, `subscriptionsActivated.starter`, `.pro`, `.unlimited`, `subscriptionsCanceled`, and `trialToPaidRate` for the live population only. Each `checkoutsOpened.*` value counts unique accounts (deduplicated by hashed account id), not checkout calls, and there is no scalar `checkoutsOpened`. It also has a `cohorts` array for the live population, one element per signup week (the ISO week, Monday UTC, of the account's trial start) that overlaps the requested range, ordered by week, each with `weekStart` (`YYYY-MM-DD`, a Monday), numeric `trialsStarted`, numeric `converted`, `convertedByTier.starter`, `.pro`, `.unlimited` (numeric, summing to `converted`), and `medianDaysToConvert` (a number of days, or `null` when `converted` is 0); an empty range yields `[]`. It also has a `qa` object with the same nine numeric fields and the same `cohorts` array for the QA population (preamble, "Funnel populations"). The live `trialToPaidRate` uses live trials and live activations only, and `qa.trialToPaidRate` uses QA trials and QA activations only. Comp grants (item 111) are not counted as activations in either population.
- **Asset:** screenshot

## M3 Trial to paid verified

M3 runs on two deployments of the same release tag.
- **TC-M3-01 to TC-M3-04 and TC-M3-05's production check** run in the production build against `{base}` with a fresh F2 created at the start of the run (sign out of F1, sign in as F2, generate one T1 draft to start the trial and throw it away with **Deny** (preamble, "Throwing a draft away"), and refresh status, as in TC-M2-06 steps 2–7), with exactly one mailbox (F1's) connected.
- **TC-M3-05's purchase through TC-M3-10** run in the **Sentwise QA** build against `{sandbox}` as F3, set up the same way in the QA build (sign in as F3, connect F1's mailbox, one T1 draft thrown away with **Deny**, refresh status). Nothing in these cases touches the production Worker or live Paddle.
- **Run order:** TC-M3-01 to TC-M3-04; TC-M3-05 steps 1–5; TC-M3-11 step 1; TC-M3-05 steps 6–15; TC-M3-06, TC-M3-07, TC-M3-10 (pausing needs a subscription with no scheduled cancellation), TC-M3-08, TC-M3-09; then TC-M3-11 steps 2–3 before the TC-M3-09 teardown launches **Sentwise**. Lucius' daily pass is paused for the run so nothing launches **Sentwise** in between.
- **If the sandbox deployment slips**, M3 runs the production fallback sequence under TC-M3-05 instead.
- The pane rounds trial days up, so each reminder fixture sets the trial end one hour inside its threshold. Trial dates are set with item 119's admin route by the `uat` executor, on `{base}` for F2 and on `{sandbox}` for F3.

### TC-M3-01 Trial override is limited to QA accounts
- **Executor:** uat
- **Verifies:** item 119
- **Preconditions:** Worker deployed with item 119; token available.
- **Steps:**
  1. `POST {base}/admin/trial` with body `{"email":"someone@example.com","startedAt":"2026-10-01T00:00:00Z"}` and the token.
  2. Repeat with no `Authorization` header and F2's email.
- **Expected:** step 1 returns 403 with error code `trial_override_forbidden`; step 2 returns 401; neither changes any account.
- **Asset:** screenshot (responses)

### TC-M3-02 Seven-day reminder
- **Executor:** uat (step 1) and lucius (steps 2–4)
- **Verifies:** items 87, 119
- **Preconditions:** F2 signed in on trial; macOS notifications allowed for Sentwise.
- **Steps:**
  1. uat: `POST {base}/admin/trial` for F2 with `startedAt` = now minus 7 days minus 1 hour (the trial now ends in 6 days 23 hours, one hour inside the 7-day threshold).
  2. lucius: quit Sentwise from the status menu (**Quit Sentwise**) and relaunch it from `/Applications`.
  3. Wait up to 2 minutes for a notification.
  4. Click the notification.
- **Expected:** one notification titled "Your Sentwise trial ends in 7 days" whose body names the end date; clicking it opens Settings on the **Subscription** tab, which shows "Trial — 7 days left".
- **Asset:** video

### TC-M3-03 One-day reminder fires once
- **Executor:** uat (step 1) and lucius (steps 2–5)
- **Verifies:** item 87
- **Preconditions:** TC-M3-02 done.
- **Steps:**
  1. uat: set F2's `startedAt` to now minus 13 days minus 1 hour (the trial now ends in 23 hours, one hour inside the 1-day threshold).
  2. lucius: quit and relaunch Sentwise; wait up to 2 minutes.
  3. Note the notification.
  4. Quit and relaunch Sentwise again; wait 2 minutes.
  5. Open Notification Center.
- **Expected:** exactly one notification titled "Your Sentwise trial ends tomorrow" appears across both launches, the Subscription tab shows "Trial — 1 day left", and the 7-day reminder does not fire again.
- **Asset:** video

### TC-M3-04 Trial ended pauses drafting
- **Executor:** uat (step 1) and lucius (steps 2–4)
- **Verifies:** item 87 (end state), item 119
- **Preconditions:** F2 signed in.
- **Steps:**
  1. uat: set F2's `startedAt` to now minus 15 days.
  2. lucius: quit and relaunch Sentwise; open **Settings…** → **Subscription**.
  3. From the status menu open **New Follow-up from Transcript…**, enter recipient `luciusfox@prowlqa.dev`, paste T1.
  4. Read the state of the **Draft follow-up** button (do not try to force it), then close the composer.
- **Expected:** the Subscription tab shows plan "Trial ended" with "Your free trial has ended, so drafting is paused until you choose a plan." and a **Subscribe** button; in step 4 **Draft follow-up** is disabled (the app's `canCreateFollowUp` is false once the trial has ended), so no draft can be requested and none appears in Review Drafts. Item 87 does not change the composer.
- **Asset:** video

### TC-M3-05 Checkout to a paid plan on the sandbox deployment; production unaffected
- **Executor:** lucius (steps 2–6 and 8–14) and uat (steps 1, 7 and 15)
- **Verifies:** item 123, item 120, item 124 (plan buttons open a working checkout), checkout regression (items 56c/90)
- **Preconditions:**
  - v0.2.2 installed as **Sentwise**; the **Sentwise QA** build of the v0.2.2 tag installed; `{sandbox}` deployed at the v0.2.2 tag (`docs/billing-qa.md`), with the sandbox catalog mirroring the tier matrix.
  - F2 on production in TC-M3-04's "Trial ended" state, signed in to **Sentwise**.
  - **The purchaser is always F3** in the Sentwise QA build. **Never purchase on F1**, on any build or path: an active Paddle subscription takes precedence over a comp (item 111's layering), so a purchase on F1 would leave the daily Pro fixture on Starter. If F1 is ever bought on by mistake, the orchestrator has the subscription **terminated immediately** (not scheduled) in Paddle, then re-grants the Pro comp and confirms the Subscription pane reads Pro.
  - Paddle sandbox test card numbers are in `docs/billing-qa.md`, not here.
  - **Deployed revisions (recorded in the run report before step 1; the orchestrator fills them, since `wrangler deployments list` reads Cloudflare with Michael's login):**
    - `service_commit`: the sentwise-service commit SHA this run verifies.
    - `sandbox_deploy_run`: the `deploy-sandbox.yml` run id, and `sandbox_commit` / `sandbox_tag`: the commit SHA and tag that run deployed.
    - `prod_version_id` and `prod_created`: the latest deployment's version id and created time from `npx wrangler deployments list` for the `sentwise-inference` Worker.
    - `prod_deploy_run` and `prod_commit`: the Deploy workflow run id and its commit SHA when that deployment came from the workflow; for a manual `wrangler deploy`, `prod_deploy_run` is `manual` and `prod_commit` is the commit the orchestrator maps it to.
    - `sandbox_commit` and `prod_commit` must both equal `service_commit`. If production is on a different commit, M3 is not accepted: production is redeployed at `service_commit` (and these fields re-read) or the run is repeated against the commit production runs.
- **Steps:**
  1. uat: `GET {base}/admin/funnel?from=<today>&to=<today>` with the token and record the production baseline: live `subscriptionsActivated.starter`, `.pro`, `.unlimited`, `subscriptionsCanceled`, and `qa.subscriptionsActivated.starter`, `.pro`, `.unlimited`, and `qa.subscriptionsCanceled`.
  2. lucius, production check, in **Sentwise** as F2: **Settings…** → **Subscription** → **Subscribe**.
  3. In "Choose your plan", click the Starter card and wait for "Secure checkout by Paddle".
  4. Read the price in the checkout form. Do not enter any card.
  5. Click **Close**; **Sign out**; sign back in as F1 and confirm the Subscription tab reads Pro.
  6. Quit Sentwise with **Quit Sentwise**, run TC-M3-11 step 1, then launch **Sentwise QA** from `/Applications`; sign in as F3 and set it up as in the M3 setup above.
  7. uat: confirm F3 is in the Clerk development instance and not in production Clerk: `GET {base}/admin/comp?email=<F3>` returns 404 `{"error":{"type":"account_not_found","message":"No account matches that email."}}`, never a 200 describing an account, while the sandbox calls below succeed. Then `POST {sandbox}/admin/trial` for F3 with `startedAt` = now minus 15 days (sandbox token). Then `GET {sandbox}/admin/comp?email=<F3>` and `GET {sandbox}/admin/funnel?from=<today>&to=<today>`; record the sandbox `qa.subscriptionsActivated.starter` and `qa.subscriptionsCanceled`.
  8. lucius, in **Sentwise QA** as F3: close and reopen **Settings…** → **Subscription**; confirm "Trial ended" and a **Subscribe** button. Then open **About** and the status menu and read the update action in each (do not click it).
  9. Click **Subscribe**; in "Choose your plan", click the Starter card and wait for "Secure checkout by Paddle".
  10. Read the price in the checkout form.
  11. Pay with the Paddle sandbox success test card from `docs/billing-qa.md`.
  12. Wait for the confirmation, then click **Done**.
  13. Close and reopen **Settings…** → **Subscription**.
  14. Keep F3 signed in to Sentwise QA for TC-M3-06, TC-M3-07, TC-M3-10, TC-M3-08.
  15. uat: `GET {sandbox}/admin/funnel?from=<today>&to=<today>`.
- **Expected:**
  - Step 4 (production check, read-only): the checkout shows the live Starter price ($9.00/month plus any tax), with no Paddle test-mode or sandbox marking, and step 5 shows Pro for F1. The production build has no sandbox configuration, so this is a single confirmation, not a routing test; no card is entered on production.
  - Step 7: the production read `GET {base}/admin/comp?email=<F3>` returns 404 with `error.type` `account_not_found` (F3 does not exist in production Clerk; any 200 stops the case). The sandbox read `GET {sandbox}/admin/comp?email=<F3>` returns 200 with `"comp": null` and `"active": false` (a missing comp on an existing account is not a 404; any `"active": true` stops the case).
  - Step 8 shows "Trial ended" with **Subscribe**. In About, **Check for Updates…** is disabled with "Updates are turned off in QA builds." under it; in the status menu the item reads **Check for Updates (Unavailable)** and is disabled (item 123: the QA build never starts its updater, so it can never fetch the production appcast). An enabled update action in Sentwise QA fails the case. Steps 9–10 open the sandbox checkout with the sandbox Starter price.
  - Step 12 shows "You're on Starter — you're all set."
  - Step 13 shows Current plan Starter with "Renews <date about one month out>".
  - Step 15: sandbox `qa.subscriptionsActivated.starter` is at least its step 7 value + 1. The production funnel is checked in TC-M3-09.
- **Asset:** video

#### Production fallback sequence (only if the sandbox deployment slips)
Payment method, in order: (a) a single-use 100%-off live Paddle discount code; (b) a real $9 Starter purchase, card entered by Michael. Record in the report which ran.
- **Setup:** no Sentwise QA build, no F3, no `{sandbox}`. The purchaser is the production F2 from TC-M3-04 ("Trial ended"), in **Sentwise** against `{base}`.
- **TC-M3-05:** run steps 1–4 as written and leave step 4's checkout open; skip steps 5–10 (F2 stays signed in, and step 4 already read the live $9.00 price that step 10 would read). Before paying, uat runs only step 7's comp read, against `{base}` for F2 (expect `"comp": null`, `"active": false`). Then continue in the **same open checkout** at step 11: enter the discount code (a) or Michael's card (b); steps 12–13 follow in **Sentwise** as F2. Step 15 reads `{base}`: production `qa.subscriptionsActivated.starter` is at least the step 1 baseline + 1 and every live counter is unchanged.
- **Downstream:** TC-M3-06, TC-M3-07 (live Paddle portal), and then TC-M3-08 directly after TC-M3-07 (its TC-M3-10 precondition is waived) run in **Sentwise** as F2. TC-M3-09 uses its alternate-path expectation. **TC-M3-10 is blocked** (no live subscription is paused for a test; item 124's paused status rests on its Vitest until the sandbox exists). **TC-M3-11 is not applicable.** Item 123 stays open.
- **Teardown:** lucius signs out of F2, signs in as F1, and confirms Pro. The orchestrator then has F2's live subscription **canceled immediately** in Paddle (not at period end; TC-M3-08's scheduled cancel is not enough), refunds a (b) charge the same day, and deletes F2 once Paddle shows it canceled. After that cancellation, uat repeats TC-M3-09 step 3: production `qa.subscriptionsCanceled` is at least the TC-M3-05 step 1 baseline + 1 and every live counter equals its baseline.

### TC-M3-06 Paid account drafts again
- **Executor:** lucius
- **Verifies:** item 120 (paid entitlement on the release)
- **Preconditions:** TC-M3-05 passed; **Sentwise QA** running as F3.
- **Steps:**
  1. Open **Settings…** → **Subscription**; record the Usage count as the baseline N. Drafts made during setup on trial count toward the month; denying does not refund one, and buying Starter does not reset the counter.
  2. Status menu → **New Follow-up from Transcript…**; recipient `luciusfox@prowlqa.dev`, subject `Pilot next steps (paid)`; paste T1; click **Draft follow-up**.
  3. Close and reopen **Settings…** → **Subscription** and read Usage.
- **Expected:** a draft is produced and Usage reads N + 1 of 30 drafts used this month.
- **Asset:** screenshot

### TC-M3-07 Manage billing opens the portal without a sign-in
- **Executor:** lucius
- **Verifies:** items 90/91 regression (same code as production, on the sandbox deployment)
- **Preconditions:** TC-M3-05 passed; **Sentwise QA** running as F3.
- **Steps:**
  1. **Settings…** → **Subscription** → **Manage billing**.
- **Expected:** the browser opens a Paddle customer-portal page (Paddle sandbox) showing the Starter subscription for F3 directly, without asking for an email sign-in.
- **Asset:** screenshot

### TC-M3-08 Scheduled cancellation shows in the app
- **Executor:** lucius
- **Verifies:** item 92
- **Preconditions:** TC-M3-10 done (F3's subscription active again); **Sentwise QA** running as F3; open the portal with **Settings…** → **Subscription** → **Manage billing**.
- **Steps:**
  1. In the portal, cancel the subscription (end of billing period) and confirm.
  2. Return to **Sentwise QA**, open **Settings…** → **Subscription**, and wait up to 60 seconds (close and reopen Settings once if needed).
- **Expected:** Current plan still reads Starter, with "Cancels on <the period end date>" instead of "Renews"; no upgrade prompt is shown. The cancellation is only scheduled here: Paddle sends `subscription.updated` with `scheduled_change` now and `subscription.canceled` only at the period end, and item 88 counts `subscriptionsCanceled` from `subscription.canceled` alone, so the funnel's canceled counter is not expected to move until TC-M3-09 step 1 ends the subscription.
- **Asset:** video

### TC-M3-09 Conversion is counted
- **Executor:** uat
- **Verifies:** item 88, item 123 (sandbox events stay off the production funnel)
- **Preconditions:** TC-M3-05 and TC-M3-08 done today; the step 1 (production) and step 7 (sandbox) baselines from TC-M3-05 are in the run notes; `uat` has `PADDLE_SANDBOX_API_KEY` and F3's sandbox subscription id (as in TC-M3-10).
- **Steps:**
  1. Make the scheduled cancellation take effect now, so Paddle sends `subscription.canceled` (item 88 counts only that event): `POST https://sandbox-api.paddle.com/subscriptions/<id>/cancel` with body `{"effective_from":"immediately"}` and the sandbox API key; expect 200 with `"status": "canceled"`. If Paddle refuses because of the pending scheduled change, first `PATCH https://sandbox-api.paddle.com/subscriptions/<id>` with `{"scheduled_change":null}`, then retry. Wait 60 seconds.
  2. `GET {sandbox}/admin/funnel?from=<today>&to=<today>` with the sandbox token.
  3. `GET {base}/admin/funnel?from=<today>&to=<today>` with the production token.
- **Expected:**
  - Step 2: sandbox `qa.subscriptionsActivated.starter` and `qa.subscriptionsCanceled` are each at least their TC-M3-05 step 7 value + 1, and sandbox `qa.trialToPaidRate` is greater than 0.
  - Step 3: production `qa.subscriptionsActivated.starter`, `.pro`, `.unlimited`, and `qa.subscriptionsCanceled` equal the TC-M3-05 step 1 baseline (the purchase and cancellation happened on the sandbox, which never reaches the production Worker), and the live `subscriptionsActivated.starter`, `.pro`, `.unlimited`, and `subscriptionsCanceled` equal the baseline too. A live counter that moved fails the case unless the orchestrator confirms in the live Paddle dashboard that the same number of real customer subscriptions changed between the two reads.
  - On an alternate path (TC-M3-05 (a) or (b)), step 1 is skipped (no sandbox) and step 3 instead shows production `qa.subscriptionsActivated.starter` at least baseline + 1 and qa `trialToPaidRate` above 0, with live counters unchanged. Production `qa.subscriptionsCanceled` is asserted after the fallback teardown's immediate cancellation, not here.
- **Asset:** screenshot
- **Teardown:** lucius quits **Sentwise QA**, launches **Sentwise**, and confirms it is signed in as F1 with the Subscription tab reading Pro. F3's sandbox subscription was already canceled in step 1. The orchestrator deletes F2 from production and F3 from the Clerk development instance. On the production fallback sequence, follow that sequence's teardown instead.

### TC-M3-10 A paused subscription pauses drafting until resumed
- **Executor:** uat (steps 1 and 4) and lucius (steps 2–3 and 5–6)
- **Verifies:** item 124 (paused is stored as paused, not canceled, and is not entitled to draft)
- **Preconditions:** TC-M3-07 done, before TC-M3-08 (no scheduled cancellation on F3's subscription); **Sentwise QA** running as F3 on Starter; `uat` has `PADDLE_SANDBOX_API_KEY` and F3's sandbox subscription id from the Paddle sandbox dashboard or the TC-M3-07 portal page.
- **Steps:**
  1. uat: `POST https://sandbox-api.paddle.com/subscriptions/<id>/pause` with body `{"effective_from":"immediately"}` and the sandbox API key; expect 200 with `"status": "paused"`.
  2. lucius: wait 60 seconds, close and reopen **Settings…** → **Subscription**, and read the plan line and the buttons shown.
  3. Status menu → **New Follow-up from Transcript…**; recipient `luciusfox@prowlqa.dev`; paste T1. Read the state of **Draft follow-up** (click it only if it is enabled), then close the composer.
  4. uat: `POST https://sandbox-api.paddle.com/subscriptions/<id>/resume` with body `{"effective_from":"immediately"}`; expect 200 with `"status": "active"`.
  5. lucius: wait 60 seconds, close and reopen **Settings…** → **Subscription**.
  6. Status menu → **New Follow-up from Transcript…**; recipient `luciusfox@prowlqa.dev`; paste T1; click **Draft follow-up**; when the draft appears, throw it away with **Deny**.
- **Expected:**
  - Step 2 shows exactly "Paused — your Starter subscription is paused. Resume it in Manage billing.", with **Manage billing** available and no **Subscribe** button and no plan cards; never "Canceled" or "Trial ended".
  - Step 3: drafting is refused while paused (Paddle is not billing, so the Worker returns 402 and the app matches it). **Draft follow-up** is disabled, or if clicked it is refused with no draft; no draft appears in Review Drafts.
  - Step 5 shows Starter with "Renews <date>" again, and step 6 produces a draft.
- **Asset:** video

### TC-M3-11 The QA build leaves the production install's data alone
- **Executor:** lucius
- **Verifies:** item 123 (local data isolation)
- **Preconditions:** **Sentwise** has been quit at TC-M3-05 step 6 and nothing relaunches it until step 3 here (daily pass paused). Steps run in Terminal on the Mini; they record file names, sizes, modification times, and SHA-256 hashes, and Keychain attributes only; they never print file contents or secret values.
- **Steps:**
  1. Before launching **Sentwise QA** (TC-M3-05 step 6, after quitting Sentwise): save this script as `/tmp/sentwise-prod-snapshot.sh`. It covers every production location item 123 requires the QA build to leave alone: the Application Support store, caches, the WebKit and HTTP storage the Paddle checkout and URLSession use, a `Logs` folder (the app logs through the unified log, so this folder should not exist; it is listed so a stray file write fails), saved window state, the defaults domain, every `Sentwise*` entry in the per-user temporary directory (recursively), and the production Keychain service `com.tookes.Sentwise` (generic-password attributes only; `dump-keychain` without `-d` never decrypts a secret). The exact-match pattern on the service excludes `com.tookes.Sentwise.qa` and `com.tookes.Sentwise.tests`.
     ```
     # fail closed: any failed command or pipeline stage aborts the script with a non-zero exit
     set -euo pipefail
     # name, size in bytes, modification time (epoch seconds), then SHA-256, for every file
     snap() { set -euo pipefail
              find "$@" -type f -print0 | sort -z | xargs -0 stat -f '%N %z %m'
              find "$@" -type f -print0 | sort -z | xargs -0 shasum -a 256; }
     for d in "Application Support/Sentwise" "Caches/com.tookes.Sentwise" "WebKit/com.tookes.Sentwise" \
              "HTTPStorages/com.tookes.Sentwise" "Logs/Sentwise" "Saved Application State/com.tookes.Sentwise.savedState"; do
       echo "## $d"
       if [ -d "$HOME/Library/$d" ]; then (cd "$HOME/Library/$d" && snap .); fi
     done
     echo "## defaults"; defaults export com.tookes.Sentwise - | shasum -a 256
     echo "## tmp"; (cd "$TMPDIR" && find . -maxdepth 1 -name 'Sentwise*' | sort && snap . -path './Sentwise*')
     echo "## keychain"; security dump-keychain "$HOME/Library/Keychains/login.keychain-db" \
       | perl -0777 -ne 'for (split /^keychain: /m) { print if /"svce"<blob>="com\.tookes\.Sentwise"$/m }' \
       | grep -E '"(svce|acct|cdat|mdat)"'
     ```
     Then run `zsh /tmp/sentwise-prod-snapshot.sh > /tmp/sentwise-prod-before.txt && date "+%Y-%m-%d %H:%M:%S" > /tmp/sentwise-qa-start.txt`, and check that `echo $?` prints `0`.
  2. After TC-M3-09's steps and before its teardown, quit **Sentwise QA** and run `zsh /tmp/sentwise-prod-snapshot.sh > /tmp/sentwise-prod-after.txt && echo snapshot-ok`.
  3. Run `diff /tmp/sentwise-prod-before.txt /tmp/sentwise-prod-after.txt`; `log show --start "$(cat /tmp/sentwise-qa-start.txt)" --predicate 'subsystem == "com.tookes.Sentwise"' --info --style compact | tail -n +2`; `ls "$HOME/Library/Application Support/Sentwise QA"`; and `security dump-keychain "$HOME/Library/Keychains/login.keychain-db" | grep -c '"svce"<blob>="com.tookes.Sentwise.qa"'`.
- **Expected:**
  - Both snapshot runs exit 0 (step 1's `echo $?` prints `0`; step 2 prints `snapshot-ok`). A non-zero exit from either snapshot run fails TC-M3-11, whatever `diff` later shows: a failed `find`, `stat`, `shasum`, `defaults export`, or Keychain filter (including a `grep` that matches no production Keychain item) means the snapshot is partial and proves nothing.
  - `/tmp/sentwise-prod-before.txt` contains a `./Settings.json` line under `## Application Support/Sentwise` and at least one `"svce"<blob>="com.tookes.Sentwise"` line under `## keychain`, so the known production store and Keychain entries were actually captured.
  - `diff` prints nothing: every production store file (`Settings.json`, drafts, voice profile, activity, and the rest), the production caches, WebKit and HTTP storage, logs folder, saved state, and `Sentwise*` temporary files keep the same names, sizes, modification times, and SHA-256 hashes across the QA run (a file overwritten in place, even with the same name, changes its mtime or hash and fails the case), the defaults domain hashes the same, and every `com.tookes.Sentwise` Keychain item has the same account and modification date (no production secret was overwritten, added, or deleted).
  - The `log show` prints no entries: nothing logged under the production subsystem while only Sentwise QA ran (its `Logger` subsystem is `com.tookes.Sentwise.qa`).
  - The `ls` lists the QA build's own store files, and the Keychain count is at least 1 (the QA build stored its mailbox and session secrets under `com.tookes.Sentwise.qa`), proving it wrote somewhere else.
- **Asset:** screenshot (Terminal with the step 3 output; the snapshots contain only names, sizes, modification times, hashes, and Keychain attributes, no content or secrets)

## M4 First-run friction cut

### TC-M4-01 Workspace domain is recognized as Gmail
- **Executor:** lucius
- **Verifies:** item 110
- **Preconditions:** Sentwise v0.2.3 as F1 (Pro, so a second account is allowed). In **Settings…** → **Account**, remove nothing; F1's mailbox is connected.
- **Steps:**
  1. Click **Add another account**.
  2. Type `luciusfox@prowlqa.dev` into **Email address** and move focus to **App password**.
  3. Wait 3 seconds, then expand **Advanced (IMAP server)**.
- **Expected:** **IMAP host** reads `imap.gmail.com` and the app-password guidance shown is the Google one; typing was never blocked. Click **Cancel** afterwards (the account is already connected).
- **Asset:** video

### TC-M4-02 Unknown domain falls back cleanly
- **Executor:** lucius
- **Verifies:** item 110 (negative)
- **Preconditions:** as TC-M4-01.
- **Steps:**
  1. Click **Add another account**; type `qa@example.com` in **Email address**; enter `abcdabcdabcdabcd` in **App password**.
  2. Click **Test Connection**.
- **Expected:** **IMAP host** stays empty and the message points at the IMAP server under Advanced as the missing field (item 109 behavior); no crash, no hang longer than the DNS timeout. Click **Cancel**.
- **Asset:** screenshot

### TC-M4-03 Continue with Google
- **Executor:** lucius
- **Verifies:** item 121, item 123 (URL scheme isolation)
- **Preconditions:**
  - Owner step done (Clerk callback allowlist, `docs/launch-checklist.md` §1); Sentwise v0.2.3 running as F1.
  - **Sentwise QA** is installed (if it exists yet) and **not running**, and it declares only `sentwise-qa`: `defaults read "/Applications/Sentwise QA.app/Contents/Info" CFBundleURLTypes` lists `sentwise-qa` and no `sentwise` entry. A `sentwise` entry there fails the case before step 1.
- **Steps:**
  1. **Settings…** → **Subscription** → **Sign out**.
  2. Click **Sign in or create your account**, then **Continue with Google**.
  3. In the browser, choose `luciusfox@prowlqa.dev` and approve.
  4. Return to Sentwise when the browser hands back.
- **Expected:** the hand-back in step 4 brings **Sentwise** (not Sentwise QA) to the front and the Subscription tab shows F1 signed in with plan Pro; Sentwise QA did not launch; no 404 or error page appeared in the browser.
- **Asset:** video

### TC-M4-04 Verification email is branded
- **Executor:** lucius
- **Verifies:** item 106
- **Preconditions:** Clerk templates customized; F1's Gmail open in a browser on the Mini.
- **Steps:**
  1. In Sentwise, sign out, click **Sign in or create your account**, enter F1 in **Email address**, continue.
  2. Open the newest message in F1's Gmail inbox.
  3. Use **Show original** on it.
- **Expected:** the sender name is "Sentwise", the from-address is on `sentwise.ai`, the body shows the Sentwise owl logo and emerald palette, and Show original reports SPF, DKIM and DMARC as PASS. Enter the code to finish signing in as F1.
- **Asset:** screenshot

### TC-M4-05 Sign-in stages are logged without personal data
- **Executor:** lucius
- **Verifies:** item 105
- **Preconditions:** TC-M4-04 completed a sign-in in the last 5 minutes.
- **Steps:**
  1. In Terminal run `log show --last 5m --predicate 'subsystem == "com.tookes.Sentwise"' --info | grep -i sign`.
- **Expected:** lines exist for each sign-in stage (verify, mint, finalize, status refresh), and none contains `@`, `prowlqa`, or a token-like string.
- **Asset:** screenshot (terminal)

### TC-M4-06 Update to v0.2.3 shows notes
- **Executor:** lucius
- **Verifies:** item 122
- **Preconditions:** v0.2.2 installed; v0.2.3 published.
- **Steps:**
  1. Status menu → **Check for Updates…**; install and relaunch.
  2. **Settings…** → **About**.
- **Expected:** the dialog showed 0.2.3 notes; About shows 0.2.3; F1 still signed in with Pro.
- **Asset:** video

## M5 Public link and 30-day push

### TC-M5-01 Stranger path from the public post
- **Executor:** lucius
- **Verifies:** item 74 (public link), genkei-ops P1-1
- **Preconditions:**
  - The public post URL from the distribution plan.
  - Run inside a **separate standard macOS user on Lucius' Mini** (`sentwise-stranger`, created once by `homelab-it`), so the stranger has no Sentwise app data, no Keychain items, and no onboarding-completed flag. Keeping F1's user would skip fresh onboarding, because `reconcileOnboardingState()` honors F1's session.
  - Before each run, the stranger user's home folder is reset (`~/Applications/Sentwise.app`, Application Support, Preferences, and login keychain removed by `homelab-it`), and `~/Applications` exists in the stranger user.
  - F1's user, app, and Keychain are not touched. The stranger installs **per user** in `~/Applications/Sentwise.app`, never in the shared `/Applications`, where F1's production app lives. Sparkle updates and launch at login behave the same from `~/Applications`.
  - Before step 1, record the shared app's fingerprint in Terminal: `find /Applications/Sentwise.app -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 > /tmp/stranger-shared-app-before.txt`.
  - The browser in the stranger user has no sentwise.ai cookies.
- **Steps:**
  1. Log in to the stranger user. Open the post URL and click its link to sentwise.ai.
  2. On sentwise.ai click **Download for macOS**.
  3. Open the downloaded DMG. In Finder choose **Go** → **Go to Folder…**, enter `~/Applications`, and drag Sentwise from the DMG window into that folder (not onto the DMG's **Applications** link, which points at the shared `/Applications`). Open `~/Applications/Sentwise.app` and accept the Gatekeeper prompt.
  4. In Setup Assistant ("Welcome to Sentwise"), connect F1's mailbox (`luciusfox@prowlqa.dev`) with its app password. Then sign in to Sentwise AI as a new F2.
  5. Finish the Setup Assistant with **Save as draft**.
  6. From the status menu open **New Follow-up from Transcript…**, enter recipient `luciusfox@prowlqa.dev`, paste T1, click **Draft follow-up**, and when the draft appears in Review Drafts throw it away with **Deny**: select **Not worth replying** and click **Deny** in the sheet (the first draft starts the trial).
  7. Close and reopen **Settings…** → **Subscription**.
  8. In Terminal, rerun the fingerprint command into `/tmp/stranger-shared-app-after.txt` and run `diff /tmp/stranger-shared-app-before.txt /tmp/stranger-shared-app-after.txt`.
- **Expected:** Gatekeeper reports the app was checked for malicious software with none detected; the installed version is the latest release; step 3 opens to the Setup Assistant (not straight to the menu bar); step 7 shows "Trial — 14 days left"; step 8's `diff` prints nothing (the shared `/Applications/Sentwise.app` is unchanged) and the running app's path is `~/Applications/Sentwise.app`. Teardown: in the stranger user, Settings → Account → disconnect the mailbox with **Disconnect & Erase Local Data**; log out of the stranger user.
- **Asset:** video

### TC-M5-02 Support mail gets a reply within the stated SLA
- **Executor:** lucius
- **Verifies:** genkei-ops P1-4 (support path drill)
- **Preconditions:** support desk live; `https://sentwise.ai/support` states the response time.
- **Steps:**
  1. From F1's Gmail send to `support@sentwise.ai` with subject `[QA drill] <date> cannot find Launch at Login` and a one-line body.
  2. Record the send time; check F1's inbox once each business day.
- **Expected:** a human-written reply arrives within the response time stated on `/support` (two business days today), and the ticket appears in the support desk.
- **Asset:** screenshot

### TC-M5-03 Report a Problem reaches the feedback inbox
- **Executor:** lucius (steps 1–6); the orchestrator verifies receipt (step 7)
- **Verifies:** item 74 (feedback inbox live)
- **Preconditions:**
  - Sentwise latest running as F1.
  - Apple Mail on the Mini is configured as the default mail client with F1's mailbox, so `mailto:` opens a compose window.
  - The shipped flow sends nothing itself and shows no confirmation. It writes a diagnostics file, reveals it in Finder, and opens a prefilled `mailto:` (`docs/feedback-diagnostics.md`).
- **Steps:**
  1. Status menu → **Report a Problem…**.
  2. Confirm Finder reveals `Sentwise-Diagnostics-<timestamp>.txt` in Downloads.
  3. Confirm a Mail compose window opened to `feedback@sentwise.ai` with the app and macOS versions in the subject or body.
  4. Prefix the subject with `[QA drill] <RUNID> `.
  5. Drag the revealed diagnostics file into the message as an attachment.
  6. Click Send and confirm the message is in F1's Sent mailbox.
  7. Orchestrator: check the `feedback@sentwise.ai` mailbox.
- **Expected:** within one hour of step 6, the `feedback@sentwise.ai` mailbox holds the `[QA drill] <RUNID>` message with the diagnostics `.txt` attached.
- **Asset:** screenshot

### TC-M5-04 Download always serves the latest release
- **Executor:** uat
- **Verifies:** item 74 (release hygiene)
- **Preconditions:** none.
- **Steps:**
  1. Read the latest release tag from `https://api.github.com/repos/michaeltookes/sentwise/releases/latest`.
  2. Request `https://sentwise.ai/download` without following redirects.
  3. On `https://sentwise.ai/pricing`, click the CTA on each of the three cards.
- **Expected:** the redirect target in step 2 is the `.dmg` asset of the tag from step 1, and every pricing-card CTA goes to `/download`.
- **Asset:** screenshot
