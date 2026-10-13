# Sentwise — project plan (replan toward the first paid subscription)

**Status:** draft 2026-10-12, awaiting Michael's approval (approval = merging `plan/sentwise-monetization`). **Pipeline item:** sentwise#plan. **Planner branch:** `plan/sentwise-monetization`. Sentwise is the pipeline's pilot app.

## Problem and users
Account Executives lose 30+ minutes a day writing post-call follow-ups and replies. Sentwise is a native macOS menu-bar app that learns the user's voice from their own Sent mail and drafts the follow-up email from a call transcript (and replies to reply-worthy mail), which the user reviews and approves in the app. No bot joins the call; mail, voice profile and transcripts stay on the Mac; drafting goes through Sentwise's stateless managed proxy, which does not log or retain request or response bodies.

- **Primary user:** "Marcus", an AE with 4–8 calls a day on a company MacBook, corporate Gmail on a Google Workspace domain, who expenses $15–20/month tools without asking.
- **Secondary:** "Priya", a technical professional who lives in email and wants drafts waiting.
- **How we know it worked (company goal):** first, one paid subscription from someone who is not Michael; then MRR covering fixed costs (Apple Developer, domains, two Workspaces, hosting, inference). The weekly measure is visitors → downloads → trials → checkouts opened → paid, by tier.

## What exists today (M0, shipped)
Sentwise **0.2.0** is live (CHANGELOG date 2026-10-07, binaries published 2026-10-08, as a paid beta; signed, notarized DMG via `sentwise.ai/download`, Homebrew cask `michaeltookes/tap/sentwise`, Sparkle auto-update). It ships: mailbox-first onboarding over IMAP + app password; voice learning; transcript → follow-up (paste, file, watched folder); inbox watching with draft-on-click and opt-in auto-drafting; Review Drafts with approve/deny-with-reason; multi-account by tier; Analytics pane; Report a Problem; Clerk email-code sign-in on production; 14-day no-card trial; Starter $9 / Pro $19 / Unlimited $39 through live Paddle (checkout sheet, plan switching, Paddle portal); server-side metering and comp entitlements (item 111). The site `sentwise.ai` (separate repo `sentwise-landing-page`) has home, pricing, FAQ, legal pages, a `/download` redirect and cookieless Vercel Web Analytics (page views only). The Worker (`sentwise-service`) serves `/v1/draft`, `/v1/me`, Paddle checkout/portal/webhook, `/admin/margin`, `/admin/comp`.

**In flight for v0.2.1 (not re-planned here):** 112 status item exposed by name (merged), 115 live-test Keychain isolation (merged), 114 Sparkle release notes in the appcast (branch `appcast-release-notes`, approved), live tests made dispatch-only (PR #99). **Not done:** the public link has not gone out (item 74's last box), the first-run onboarding leg on a clean Mac is unfinished (74 §6), the site has no changelog page and its pricing cards predate the tier matrix, nothing counts trials or conversions, and no one has bought a plan on production except under comp.

## Architecture and stack (unchanged)
- **App:** Swift/SwiftUI menu-bar app, `Sentwise/` Xcode project plus `Packages/SentwiseMail` (swift-nio-imap). Release through the CI tag pipeline (`docs/releasing.md`, `/release-prep`).
- **Service:** Cloudflare Worker `sentwise-service` (TypeScript, Vitest, Wrangler), Clerk production instance, Paddle Billing live, Workers Analytics Engine for aggregate, pseudonymized metrics. Production deploys are Michael's.
- **Site:** Next.js 16 on Vercel (`sentwise-landing-page`), MDX wired but unused.
- **QA:** Lucius on the Agent Mac Mini (Peekaboo, screen recording) for the app; the `uat` agent with Playwright, also on the Mini, for the site and HTTP endpoints. Never the MacBook.
- **No seed database.** The fixtures are QA accounts and a fixture transcript, defined in the preamble of `docs/qa/test-cases.md`; there is no `docs/qa/seed-data.md`.

## Scope: in / out (this replan)
**In:** ship v0.2.1; make the funnel measurable; prove trial → paid → cancel end to end on production; remove the first-run friction a stranger hits before paying; send the public link and run the 30-day distribution push.
**Out until after the first paid subscription:** Zoom/Teams integrations (53), calendar awareness (52), bundled Google OAuth + CASA (104), Slack (30), native capture (54), CRM (55), Windows waitlist (site 7). They stay in the backlog as ranked items; none is planned into a milestone.

## Milestones
Ordered by distance to the first paid subscription. Each app-side milestone ends with a release so Lucius tests a signed production build.

| ID | Name | Demo (what the QA video shows) | Exit criteria |
|---|---|---|---|
| M1 | v0.2.1 ships | On Lucius' Mini, Sparkle offers 0.2.1 over 0.2.0 with release notes in the dialog; Peekaboo opens the "Sentwise" status menu by name; the Setup Assistant finishes and the first follow-up and first inbox reply are approved as drafts | v0.2.1 released; TC-M1-* pass; 74 §6 onboarding box ticked |
| M2 | Funnel is measurable | `sentwise.ai/changelog` lists 0.2.1 and 0.2.0; pricing cards show per-tier features; `GET /admin/funnel` returns the week's trials, checkouts opened and paid by tier | Site and Worker deployed; TC-M2-* pass; first funnel row in `genkei-ops/docs/metrics.md` |
| M3 | Trial → paid verified | A fresh QA account goes trial → 7-day and 1-day reminders → "Trial ended" → Subscribe → Paddle checkout → "You're on Starter" → drafts again → cancels and sees "Cancels on <date>" | Item 123 sandbox deployment live (`sentwise-inference-sandbox`: Paddle sandbox, Clerk development instance, own Durable Object and funnel dataset) at the 0.2.2 tag, and a "Sentwise QA" build of the 0.2.2 tag pointing at it; item 124 fixes in; v0.2.2 released; TC-M3-* pass, with the purchase made in the QA build on the sandbox deployment and the production build shown to still get live prices |
| M4 | First-run friction cut | A Workspace custom-domain mailbox connects with the IMAP host pre-filled; "Continue with Google" signs in; the verification email arrives branded as Sentwise | v0.2.3 released; TC-M4-* pass |
| M5 | Public link and 30-day push | Following the public post's link on a clean browser: sentwise.ai → Download for macOS → install → trial started; a support drill ticket is answered within the stated SLA | Item 74 closed; distribution plan live; TC-M5-* pass; funnel reported weekly |

**M1 is under one builder-week:** 113 (about a day), 116 (half a day), merging the approved 114 branch, and the release cut (117). QA work on 74 §6 runs in parallel on Lucius.

### Items per milestone (IDs live in `docs/backlog.md`; other repos' items are filed by the orchestrator)
| Milestone | sentwise items | Other repos and genkei-ops |
|---|---|---|
| M1 | 113, 116, 117; in flight: 112, 114, 115; QA leg of 74 (§6 onboarding) | genkei-ops P1-3 (QA waves 2–3), PR #99 |
| M2 | 88, 118 | sentwise-landing-page 10 (changelog page = genkei-ops 6c-1), 14 (pricing cards = 6c-2); genkei-ops P1-2 (funnel instrumentation, weekly pull into `metrics.md`) |
| M3 | 123 (prerequisite), 124, 119, 87, 92, 120 | sentwise-service work is carried by 88/118/119/92/123/124 (that repo has no backlog; shared items use sentwise numbers). The `paddle-sandbox-lane` branches were closed unmerged on 2026-10-13; 123 is rebuilt as a sandbox deployment, 124 carries the two production fixes cherry-picked from them. Vendor setup for the sandbox (Paddle sandbox catalog and webhook, Clerk development instance) runs through `/vendor-config` |
| M4 | 110, 105, 106, 121, 122 | Clerk dashboard steps (owner): callback allowlist (74 §1), email branding (106) |
| M5 | 74 (close) | genkei-ops P1-1 (distribution plan), P1-4 (support path drill), 6c-3/6c-4/6c-5 (social handles, update email, founder voice), Stage 5 launch kit (`/launch-kit sentwise v0.2.3`); sentwise-landing-page 9 (demo video) |

## Risks
- **The purchase test runs on a separate sandbox deployment (item 123, re-scoped 2026-10-13).** A second Worker, `sentwise-inference-sandbox`, runs the same code configured for the Paddle sandbox and a Clerk development instance, and a "Sentwise QA" build of the app points at it. Production carries no sandbox state, so sandbox prices cannot leak to customers by construction; TC-M3-05 keeps one read-only check that the production build still shows live prices. If the sandbox deployment slips, the fallbacks are a single-use 100%-off live discount code, then a real $9 Starter purchase refunded the same day.
- **The two services must stay in lockstep.** A purchase test on the sandbox only proves production if both Workers run the same code: every tag is deployed to both (production on merge, sandbox by dispatching its job with the same tag), the QA build is cut from the release tag it verifies, and `docs/billing-qa.md` records the sandbox's deployed tag. A run report that cannot show matching tags is not evidence for that release. Configuration drift (a secret, a price ID, a binding added to production only) is the remaining gap; every new binding or var goes into both `wrangler` environments in the same change.
- **Two Sentwise apps on the QA Mini.** The QA build has its own bundle identifier, name, status-item label, Keychain service, Application Support directory, defaults suite, and URL scheme (`sentwise-qa://`) so it cannot overwrite production data or catch production sign-in callbacks (TC-M3-11, TC-M4-03) (the 2026-10-11 Keychain incident, item 115); Lucius quits one before driving the other.
- **Clerk may block plus-addressed emails** (a dashboard restriction). The trial fixtures use `luciusfox+trial-<date>@prowlqa.dev`; if blocked, they need the wave-2 test mailbox (Michael's one-time Workspace step, genkei-ops P1-3).
- **Signing the QA Mac into a trial account disturbs Lucius' daily pass.** Every M2/M3 case that switches accounts ends by signing back in as the comped account and deleting the throwaway account.
- **Free Vercel Analytics has no custom events**, so the site funnel stage is page views plus GitHub release download counts, not click-level. Open question 2.
- **Google sign-in depends on an owner dashboard step** (Clerk callback allowlist). If it slips, 121 slips; M4 still ships with 110/105/106.
- **The distribution channel is not chosen yet** (genkei-ops P1-1). M5's demo uses whichever post that plan produces; if none exists by M5, M5 waits, but M1–M4 do not.

## Marketing angle
**"Your follow-up is written the moment your call ends — in your voice, from your own mailbox."** For AEs who already run a notetaker: Fathom, Granola and Otter give you a summary stuck in their app and keep your calls in their cloud; Sentwise turns any transcript into a send-ready email that sounds like you, nothing is stored on Sentwise's servers or used for training, and you approve every word. Proof points a writer can use: no bot joins the call, no API keys, 14-day trial with no card, $9/$19/$39 monthly, native Mac app. Do not claim "before you end your call" (item 86 is not built) or model-provider zero retention. The beta story (0.x, built in public, open core) suits founder-led channels: a launch post on sentwise.ai/changelog, LinkedIn (the AE audience lives there), and the sales-community subreddits and Slack groups the distribution plan picks one of. The update email and changelog entries come from each release's CHANGELOG section.

## Assumptions
1. Versions: M1 = 0.2.1, M3 = 0.2.2, M4 = 0.2.3, all paid-beta 0.x. Michael may rename; the milestone IDs do not change.
2. The QA account `luciusfox@prowlqa.dev` stays comped Pro (item 111) as the standing fixture; trial and purchase cases use throwaway plus-addressed accounts created and deleted in the case.
3. Funnel counts are server-side billing and licensing events (no opt-in needed, as item 88 records) plus site page views and GitHub download counts. The app sends no new telemetry; item 35/83 opt-in rules are unchanged.
4. Item 88 lands as `GET /admin/funnel` behind the existing `ADMIN_TOKEN` gate; the weekly pull into `genkei-ops/docs/metrics.md` is genkei-ops P1-2's job.
5. The trial-backdate route (119) is restricted to an allowlisted QA email domain so it can never alter a customer's trial.
6. The changelog page content is the release's CHANGELOG section, adapted by `marketing-writer` at Stage 5; the site item only builds the route.
7. The sandbox Worker adds no meaningful cost: it runs on the existing Cloudflare plan, the Clerk development instance and Paddle sandbox are free, and its inference key carries a low spend cap.
8. A paused Paddle subscription is not billed, so it is not entitled to draft: the Worker returns 402 and the app shows the paused state with **Manage billing** until it is resumed (item 124). Michael can reverse this.
9. Item 104 (bundled Google OAuth, CASA $500–1,000/yr) stays after the first paid subscription (open question 3).

## Open questions for Michael
1. **Production purchase test (money). Resolved 2026-10-12, re-scoped 2026-10-13:** Michael chose to build the QA purchase path now (item 123, an M3 prerequisite), and on 2026-10-13 chose a separate sandbox deployment of sentwise-service over a per-account lane in the production Worker. The 100%-off live discount code and a refunded $9 purchase remain fallbacks only, if the sandbox deployment slips.
2. **Click-level funnel (money).** Free Vercel Analytics gives page views and referrers but no custom events (download clicks, pricing CTA clicks); Vercel Pro is about $20/month, Plausible about $9/month. **Proceeding with no new spend:** page views + GitHub release download counts + Worker counters.
3. **Item 104 timing (money and direction).** Is bundled "Sign in with Google" for Gmail (the app-password replacement, CASA assessment $500–1,000/yr and a 2–6 week Google review) wanted before the public push, or after the first paid subscription? **Proceeding on after.** M4 cuts friction with MX auto-detect (110) and Google account sign-in (121) instead.
