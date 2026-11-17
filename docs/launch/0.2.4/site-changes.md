# Site changes for Sentwise 0.2.4

Apply on branch `site/0.2.4` in each repo via a builder work order. Prices and gates from `sentwise/docs/tier-matrix.md`; claim wording per `sentwise-landing-page/CLAUDE.md`. Checked against `sentwise-landing-page` main at 679bb58 and `sentwise` origin/main at 3c3e78f.

## sentwise-landing-page (sentwise.ai)

- [ ] APPROVED 2026-11-16 (legal copy; Michael signed off on the lead-in): `src/app/privacy/page.tsx` lines 119-121 and 166-169 describe connecting Gmail with **Sign in with Google**. Per CHANGELOG 0.2.3, one-click Google sign-in stays switched off in this build until Google's app review is complete, and 0.2.4 does not change that. Keep the section (it carries the Google API Limited Use disclosure) and add this lead sentence before "If you connect": "Sign in with Google is the main way Sentwise connects to Gmail, but it is not available in the current release. Until it is, Sentwise connects Gmail with a Google app password."
- [ ] `src/components/FAQList.tsx` (no FAQ currently says how Gmail is connected; grep for "app password" in `src/components` returns nothing). Proposed new question: **"How do I connect Gmail?"** Answer: "Sentwise connects with your Gmail address and a Google app password, which requires 2-Step Verification on your Google account. For Google Workspace accounts, your admin must allow IMAP and app passwords. Outlook and Microsoft 365 accounts cannot be connected yet." Source: README Quickstart and Roadmap.
- [ ] `src/components/FAQList.tsx` or support page: add **"Does Sentwise record my calls?"** Answer: "No. Sentwise does not record or transcribe calls and no bot joins them. You give it a transcript: paste it, choose a `.txt`, `.md`, `.vtt` or `.srt` file, or point Sentwise at a folder it watches." Source: `docs/post-call-followups.md`. Only if the FAQ does not already cover it; check the existing entries first.
- [x] `src/components/Hero.tsx:83` "Free 14-day trial · no credit card · macOS 14+". Verified, no change.
- [x] `src/components/DownloadDetails.tsx` "Requires macOS 14 (Sonoma) or later. Updates install automatically via Sparkle." Verified, no change. It deliberately has no `brew install` line (item 13 guardrail), so the Homebrew command appears only in the GitHub release text and the blog, not on the site.
- [x] `src/app/download/route.ts` resolves the latest release at request time, so it serves the 0.2.4 DMG with no redeploy. Verified, no change; confirm after publishing (checklist step 1).
- [x] `src/components/PricingTiers.tsx`, `src/app/pricing/page.tsx`: prices and allotments are the tier matrix's. Verified, no change.
- [x] `src/components/WhyDifferent.tsx`: privacy wording stays on the approved sentences, no zero-retention claim. Verified, no change.
- [x] No version string appears on the landing page. Verified, no change.

## sentwise (GitHub README)

- [ ] `README.md` line 18, release note: "This README describes Sentwise 0.2.3, the current signed DMG and Homebrew package." Proposed: "This README describes Sentwise 0.2.4, the current signed DMG and Homebrew package."
- [ ] `README.md` line 85, Quickstart: "The current package installs Sentwise 0.2.3." Proposed: "The current package installs Sentwise 0.2.4."
  Do not edit README on `launch/0.2.4`: the BA folds these two lines into the 0.2.4 rollout-plan item; they are listed here so they are not lost.
  Note: 0.2.4's release pipeline now appends the Quickstart link to every release, so these two lines are the first thing a new reader sees. Apply on `site/0.2.4` or fold into the next docs PR.

## genkei-labs (genkeilabs.com)

- Not checked in this pass (outside the work order's read list). Add if the Sentwise blurb carries a version string.

Branch for the builder: `site/0.2.4`.
