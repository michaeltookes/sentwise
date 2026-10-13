# Sentwise — test cases

Predetermined cases for the milestones in `docs/plan.md`, written before the code. QA runs them verbatim; IDs `TC-M<n>-<nn>` never change once published. A case that a build cannot pass is a defect or a backlog item, never an edited case. Where a case quotes UI text or an endpoint for work not yet built (items 87, 88, 92, 113, 118, 119), the quoted text is the spec the builder implements.

## Preamble

**Where QA runs.** Everything runs on Lucius' Mac Mini (the Agent Mini), never on the maintainer's MacBook.
- `executor: lucius` cases drive the installed, signed Sentwise app in `/Applications` with Peekaboo and capture with screen recording (`screencapture -V`) or screenshots.
- `executor: uat` cases drive a browser with Playwright or call HTTP endpoints, also on the Mini.

**Relation to the daily pass.** Lucius already runs a daily QA pass from `SENTWISE_QA.md` in his workspace (settings sweep, install-path checks, the status-menu recipe, a read of the Subscription pane). That pass is regression monitoring and keeps running. These cases are milestone acceptance: run each milestone's cases once against the release that milestone ships, and re-run only the affected cases after a fix.

**Assets.** `screenshot` means one per step; the last one is the evidence. `video` means one recording of the whole case. Redact codes, tokens, and any mailbox content that is not the fixture's own. Reports go to `docs/qa/runs/<date>-<milestone>/report.md` on a `qa/<date>-<milestone>` branch; videos stay local and are linked by path.

**Fixtures** (no seed database; these are the fixtures):
- **F1, the standing QA account:** `luciusfox@prowlqa.dev`. The same address is the connected Gmail (Google Workspace on the `prowlqa.dev` domain) and the Sentwise account, which carries a comped **Pro** plan (item 111), so the Subscription pane reads Pro, active. Credentials live in Lucius' workspace secrets and the password manager, never in this repo. Every case that signs the app into another account ends by signing back in as F1.
- **F2, a throwaway trial account:** `luciusfox+trial-<YYYYMMDD>@prowlqa.dev`, using the run date. Sentwise sign-in codes for F2 arrive in F1's Gmail inbox (plus addressing). F2 is created inside the case by signing in, and removed in teardown.
- **T1, the fixture transcript.** Paste exactly:
  ```
  Dana (Acme): Thanks for walking us through the pilot today.
  Lucius: Happy to. To recap, you want 10 seats for a 30-day pilot starting November 2.
  Dana (Acme): Right. I need the security questionnaire back by Friday.
  Lucius: I'll send it Thursday, along with the pilot order form.
  Dana (Acme): Great. Let's meet again on November 9 to review results.
  ```
- **Mail safety:** every draft is addressed only to `luciusfox@prowlqa.dev`, and send behavior is **Save as draft**. No case sends mail to anyone else.
- **Admin endpoints:** `uat` reads `SENTWISE_ADMIN_TOKEN` from its run environment on the Mini (provisioned by Michael). The token never appears in a step, a log, or an asset; screenshots of requests show the header as `Bearer ***`. Worker base URL: `https://sentwise-inference.sentwise-service.workers.dev`.
- **Opening the status menu:** click the menu-bar status item whose accessibility label is "Sentwise" (identifier `sentwise.statusItem`). Settings opens from the status menu item **Settings…**; its tabs are General, Account, AI, Subscription, Analytics, Rules, About.

## M1 v0.2.1 ships

### TC-M1-01 Sparkle update shows release notes
- **Executor:** lucius
- **Verifies:** items 114, 117
- **Preconditions:** Sentwise 0.2.0 (build 5) installed in `/Applications` and running, signed in as F1; v0.2.1 published (GitHub release, appcast, cask).
- **Steps:**
  1. Open the status menu and click **Check for Updates…**.
  2. Wait for the update dialog.
  3. Scroll the release-notes area to the bottom.
- **Expected:** the dialog reads "Sentwise 0.2.1 is now available" and its release-notes area shows the 0.2.1 CHANGELOG section with at least one heading and one bullet; it is not blank.
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

### TC-M1-08 First follow-up on a clean onboarding path
- **Executor:** lucius
- **Verifies:** item 74 (§6 onboarding leg)
- **Preconditions:** Sentwise 0.2.1 running as F1 with the mailbox connected; send behavior **Save as draft** (Setup Assistant or Settings); voice not yet learned, or **Forget voice profile** run in Settings → AI.
- **Steps:**
  1. Open **Settings…** → **AI**, and in the Voice section start learning the voice; wait until it reports a learned profile.
  2. From the status menu click **New Follow-up from Transcript…**.
  3. In **Recipients** enter `luciusfox@prowlqa.dev`; in **Subject** enter `Pilot next steps`.
  4. Paste T1 into the transcript area and click **Draft follow-up**.
  5. When the draft-ready notification appears, click it (or click **Open Review Drafts**).
  6. In Review Drafts, expand the draft and click **Approve**.
  7. In Gmail on the Mini, open Drafts for `luciusfox@prowlqa.dev`.
- **Expected:** the saved draft "Pilot next steps" is in Gmail Drafts, addressed only to `luciusfox@prowlqa.dev`, and mentions the security questionnaire by Friday and the November 9 meeting.
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
- **Executor:** uat (steps 1 and 6) and lucius (steps 2–5)
- **Verifies:** item 88
- **Preconditions:** Sentwise running as F1; `uat` has the admin token.
- **Steps:**
  1. uat: `GET {base}/admin/funnel?from=<today>&to=<today>` with the token; note `trialsStarted`.
  2. lucius: **Settings…** → **Subscription** → **Sign out**.
  3. Click **Sign in or create your account**, enter F2 in **Email address**, continue.
  4. Read the code from F1's Gmail inbox, enter it in **6-digit code**, verify.
  5. Confirm the Subscription tab shows "Trial — 14 days left" (or 13 if the day rolled over in UTC).
  6. uat: repeat step 1.
- **Expected:** `trialsStarted` in step 6 is at least one higher than in step 1. Keep F2 signed in for TC-M2-07.
- **Asset:** video

### TC-M2-07 Opening checkout is counted
- **Executor:** lucius (steps 1–4) and uat (step 5)
- **Verifies:** item 118
- **Preconditions:** TC-M2-06 done, F2 signed in on trial; uat noted `checkoutsOpened` for today.
- **Steps:**
  1. **Settings…** → **Subscription** → **Subscribe**.
  2. In "Choose your plan", click the Starter card.
  3. Wait until the Paddle checkout form ("Secure checkout by Paddle") renders.
  4. Click **Close**. Then **Sign out**, and sign back in as F1.
  5. uat: `GET {base}/admin/funnel?from=<today>&to=<today>`.
- **Expected:** `checkoutsOpened` is at least one higher than before step 1, and `subscriptionsActivated.starter` is unchanged; no purchase was made.
- **Asset:** video

### TC-M2-08 Funnel response shape
- **Executor:** uat
- **Verifies:** items 88, 118
- **Preconditions:** token available.
- **Steps:**
  1. `GET {base}/admin/funnel?from=2026-10-01&to=2026-10-31` with the token.
- **Expected:** 200 JSON with numeric fields `trialsStarted`, `checkoutsOpened`, `subscriptionsActivated.starter`, `.pro`, `.unlimited`, `subscriptionsCanceled`, and `trialToPaidRate`; comp grants (item 111) are not counted as activations.
- **Asset:** screenshot

## M3 Trial to paid verified

All M3 app cases use a fresh F2 created at the start of the run (sign out of F1, sign in as F2, as in TC-M2-06 steps 2–4), with exactly one mailbox (F1's) connected. Trial dates are set with item 119's admin route by the `uat` executor.

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
  1. uat: `POST {base}/admin/trial` for F2 with `startedAt` = now minus 7 days plus 1 hour.
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
  1. uat: set F2's `startedAt` to now minus 13 days plus 1 hour.
  2. lucius: quit and relaunch Sentwise; wait up to 2 minutes.
  3. Note the notification.
  4. Quit and relaunch Sentwise again; wait 2 minutes.
  5. Open Notification Center.
- **Expected:** exactly one notification titled "Your Sentwise trial ends tomorrow" appears across both launches; the 7-day reminder does not fire again.
- **Asset:** video

### TC-M3-04 Trial ended pauses drafting
- **Executor:** uat (step 1) and lucius (steps 2–5)
- **Verifies:** item 87 (end state), item 119
- **Preconditions:** F2 signed in.
- **Steps:**
  1. uat: set F2's `startedAt` to now minus 15 days.
  2. lucius: quit and relaunch Sentwise; open **Settings…** → **Subscription**.
  3. From the status menu open **New Follow-up from Transcript…**, enter recipient `luciusfox@prowlqa.dev`, paste T1.
  4. Click **Draft follow-up**.
  5. Read the result.
- **Expected:** the Subscription tab shows plan "Trial ended" with "Your free trial has ended, so drafting is paused until you choose a plan." and a **Subscribe** button; step 4 produces no draft and shows a message that the trial has ended with a way to choose a plan.
- **Asset:** video

### TC-M3-05 Checkout to a paid plan on production
- **Executor:** lucius; Michael completes step 4 if payment details are required (open question 1 in `docs/plan.md`)
- **Verifies:** production Paddle checkout (items 56c/90 regression), item 120
- **Preconditions:** TC-M3-04 state on v0.2.2; the test purchase method approved by Michael (100%-off discount code, or a real card refunded the same day).
- **Steps:**
  1. **Settings…** → **Subscription** → **Subscribe**.
  2. In "Choose your plan", click the Starter card.
  3. In the Paddle form, enter F2's email if asked and the approved discount code.
  4. Complete payment.
  5. Wait for the confirmation.
  6. Click **Done**.
- **Expected:** the sheet shows "You're on Starter — you're all set."; after **Done**, the Account section shows Current plan Starter with "Renews <date about one month out>".
- **Asset:** video

### TC-M3-06 Paid account drafts again
- **Executor:** lucius
- **Verifies:** item 120 (paid entitlement on the release)
- **Preconditions:** TC-M3-05 passed.
- **Steps:**
  1. Repeat TC-M1-08 steps 2–4 with subject `Pilot next steps (paid)`.
  2. Open **Settings…** → **Subscription** and read Usage.
- **Expected:** a draft is produced and Usage shows 1 of 30 drafts used this month.
- **Asset:** screenshot

### TC-M3-07 Manage billing opens the portal without a sign-in
- **Executor:** lucius
- **Verifies:** items 90/91 regression on production
- **Preconditions:** TC-M3-05 passed.
- **Steps:**
  1. **Settings…** → **Subscription** → **Manage billing**.
- **Expected:** the browser opens a Paddle customer-portal page showing the Starter subscription for F2 directly, without asking for an email sign-in.
- **Asset:** screenshot

### TC-M3-08 Scheduled cancellation shows in the app
- **Executor:** lucius
- **Verifies:** item 92
- **Preconditions:** TC-M3-07 portal page open.
- **Steps:**
  1. In the portal, cancel the subscription (end of billing period) and confirm.
  2. Return to Sentwise, open **Settings…** → **Subscription**, and wait up to 60 seconds (close and reopen Settings once if needed).
- **Expected:** Current plan still reads Starter, with "Cancels on <the period end date>" instead of "Renews"; no upgrade prompt is shown.
- **Asset:** video

### TC-M3-09 Conversion is counted
- **Executor:** uat
- **Verifies:** item 88
- **Preconditions:** TC-M3-05 and TC-M3-08 done today.
- **Steps:**
  1. `GET {base}/admin/funnel?from=<today>&to=<today>` with the token.
- **Expected:** `subscriptionsActivated.starter` ≥ 1 and `subscriptionsCanceled` ≥ 1 for today.
- **Asset:** screenshot
- **Teardown:** lucius signs out of F2 and back in as F1, then confirms the Subscription tab reads Pro. The orchestrator refunds the purchase if one was charged and deletes F2 once its cancellation takes effect.

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
- **Verifies:** item 121
- **Preconditions:** owner step done (Clerk callback allowlist, `docs/launch-checklist.md` §1); Sentwise v0.2.3 as F1.
- **Steps:**
  1. **Settings…** → **Subscription** → **Sign out**.
  2. Click **Sign in or create your account**, then **Continue with Google**.
  3. In the browser, choose `luciusfox@prowlqa.dev` and approve.
  4. Return to Sentwise when the browser hands back.
- **Expected:** the Subscription tab shows F1 signed in with plan Pro; no 404 or error page appeared in the browser.
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
- **Preconditions:** the public post URL from the distribution plan; Sentwise removed from `/Applications` on the Mini (drag to Trash; app data kept); a browser profile with no sentwise.ai cookies.
- **Steps:**
  1. Open the post URL and click its link to sentwise.ai.
  2. On sentwise.ai click **Download for macOS**.
  3. Open the downloaded DMG and drag Sentwise to Applications; open it and accept the Gatekeeper prompt.
  4. In Setup Assistant, sign in to Sentwise AI as a new F2.
- **Expected:** Gatekeeper reports the app was checked for malicious software with none detected; the installed version is the latest release; after step 4 the Subscription tab shows "Trial — 14 days left". Teardown: sign back in as F1.
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
- **Executor:** lucius
- **Verifies:** item 74 (feedback inbox live)
- **Preconditions:** Sentwise latest as F1.
- **Steps:**
  1. Status menu → **Report a Problem…**; enter `[QA drill] <date> report path`; include diagnostics; send.
- **Expected:** the app confirms sending, and the orchestrator confirms the message reached `feedback@sentwise.ai` within one hour.
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
