# Launch checklist, Sentwise 0.2.4

Owner of every publish step: Michael. Copy lives in `docs/launch/0.2.4/`. Public link approved 2026-11-16 (backlog item 74, milestone M5 "Public link and 30-day push"). Download link: https://sentwise.ai/download. Tracked links: placeholders `{UTM_X_1}`, `{UTM_X_2}`, `{UTM_X_3}`, `{UTM_LINKEDIN}`, `{UTM_EMAIL}`, `{UTM_RELEASE}` stay until the campaign-producer supplies them; until then use the plain link.

## Known at launch (open items, approved to go anyway)

- Item 129 (Slice A, TC-74-08): a real-dollar production Paddle purchase and portal-session proof has not been performed by a non-comp trial. A first paying customer is the first real test of checkout and the billing portal.
- Item 130 (Slice B, TC-74-01..07): Run 1 on 2026-10-27 scored 0 PASS under the strict evidence gate (functional passes, video missing). In Run 2, TC-74-07, the Sparkle update leg (0.2.1 to 0.2.4 on a real install), is still held.
- Item 131 (Slice C, TC-74-09): the 0.2.4 build 8 channel rerun on 2026-11-16 passed every substantive check (DMG notarized and stapled, cask 0.2.4, appcast build 8, Ed25519 signature verified, download redirect correct). The one FAIL is a test-case wording defect: C5.4 requires an Added heading that 0.2.4 legitimately lacks.
- Not yet verified from item 131, each listed again where it bites below: Sparkle update dialog on a real install (TC-74-07), feedback@sentwise.ai receipt, offline key match.
- No open P1 or P2 product defects tagged launch were found in the backlog.

## 0. Release exists (verify only)

- [ ] GitHub release `v0.2.4` published, DMG attached (verified by the item 131 rerun).
- [ ] Appcast shows build 8; Homebrew cask is 0.2.4 (verified by the rerun).
- [ ] **Not yet verified, TC-74-07:** a real 0.2.1 or 0.2.3 install shows the Sparkle update dialog and updates to 0.2.4. The existing-user email and the release announcement say installs update through the in-app updater. Until this passes, soften both to "download the DMG or run `brew upgrade --cask sentwise`" or hold the email.
- [ ] **Not yet verified:** a message to feedback@sentwise.ai arrives in the inbox that is monitored. Report a Problem and the support page rely on it.
- [ ] **Not yet verified:** offline key match (the Ed25519 public key in the app matches the one that signed the appcast, checked offline). The rerun verified the appcast signature but did not run this check.
- [ ] Open https://sentwise.ai/download in a private window; it redirects to `Sentwise-0.2.4.dmg`, which opens without a Gatekeeper warning on a clean Mac.

## 1. Site copy

- [ ] Decide the privacy-page item in `site-changes.md` (Sign in with Google wording) before pointing traffic at the site.
- [ ] Apply the FAQ additions and README version lines from `site-changes.md` (branch `site/0.2.4`); open https://sentwise.ai in a private window and check hero, pricing, FAQ.

## 2. Release announcement

- [ ] Replace the GitHub release body with `release-announcement.md`: `gh release edit v0.2.4 --notes-file docs/launch/0.2.4/release-announcement.md`. Note the current body ends with the Quickstart link the pipeline appends; keep that link when pasting.
- [ ] Site news or changelog page: none exists (landing-page item 10). Skip.

## 3. Blog post

- [ ] No blog surface on sentwise.ai. Keep `blog-post.md` in the repo; publish when landing-page item 10 or genkei-labs item 11 ships, with the original date.

## 4. Email to account holders

- [ ] Send `email.md` from support@sentwise.ai. Open question: which tool holds the list and sends (nothing is wired to send to Clerk's account emails).

## 5. Social

- [ ] X: post `social.md` posts 1 to 3 over three days. Open question: which account (and whether it is Michael's, which changes the voice, see question 1).
- [ ] LinkedIn: post the LinkedIn text. Open question: company page or personal profile. Voice guide says LinkedIn is deferred (decisions 2026-10-14), so confirm before posting.

## 6. Verify after publishing

- [ ] The download link in each post resolves to the 0.2.4 DMG.
- [ ] A new trial from a clean browser reaches Hero, download, install and a first draft (M5 acceptance).
- [ ] A test message to support@sentwise.ai is answered inside the support SLA.

## 7. Record

- [ ] Friday metrics entry: downloads (GitHub), site visits, trials started, first paid conversions. Report back so the orchestrator logs the publish steps in the ledger.
