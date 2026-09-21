# Launch cutover checklist (backlog item 74)

The ordered, tickable checklist for the production cutover and 1.0 release.
Owner-hands steps are marked **[owner]** (dashboard/DNS/hardware work); agent
steps **[agent]** (code/config flips, deploys, verification). Tick boxes as
steps complete; this document closes with item 74 when the public link goes
out.

Context docs: `docs/tier-matrix.md` (prices/caps), `docs/managed-inference.md`
(auth + worker architecture), `docs/security-pass-2026-09-13.md` (audit),
`docs/releasing.md` / `docs/ci-release.md` (release pipeline).

---

## 1. Production Clerk instance

Today the app compiles in the **dev** instance
(`ClerkClient.defaultFrontendAPIBaseURLString = https://peaceful-eel-9660.clerk.accounts.dev`,
`ClerkClient.swift:199`) and the worker ships the matching `pk_test_…`
publishable key (`wrangler.jsonc` `CLERK_PUBLISHABLE_KEY`) + `CLERK_SECRET_KEY`
secret. Security finding A-M1.

- [x] **[owner]** Create the **production instance** in the Clerk dashboard
      (Development → Production on the existing app). Home domain:
      `sentwise.ai`.
- [x] **[owner]** Add the DNS records Clerk requests (CNAMEs on
      `clerk.sentwise.ai` etc.) in Cloudflare — **DNS-only/grey-cloud**, not
      proxied, same as the landing-page CNAME. Wait for Clerk to show all
      records verified + SSL issued.
- [x] **[owner]** Google OAuth for production (Clerk prod instances require
      your own client, not Clerk's shared dev credentials):
      - Google Cloud console → new project (or reuse) → OAuth consent screen:
        External, app name **Sentwise**, domain `sentwise.ai`, logo. Scopes:
        basic OpenID/email/profile only — no sensitive scopes, so no CASA.
      - **Submit consent-screen brand verification immediately** — it can take
        days and is this step's external clock.
      - Create an OAuth **Web application** client; authorized redirect URI =
        the exact URI Clerk's prod instance shows under SSO connections →
        Google (custom credentials). Paste client id/secret into Clerk.
- [x] **[owner]** Enable the same sign-in methods as dev (email code +
      Google), and confirm session lifetime settings match dev.
- [ ] **[owner]** Clerk dashboard → allowlist the worker callback redirect for
      the managed OAuth flow (item 89):
      `https://sentwise-inference.sentwise-service.workers.dev/auth/callback`.
- [x] **[agent]** Until the production callback allowlist is complete, keep
      managed Google sign-in hidden and blocked in the app
      (`AppState.isManagedGoogleSignInEnabled = false`); re-enable only after
      the owner step above is checked and production Google sign-in is verified.
- [x] **[agent]** Worker: set `CLERK_PUBLISHABLE_KEY` var to the `pk_live_…`
      key; `wrangler secret put CLERK_SECRET_KEY` with the `sk_live_…` key
      (from a real TTY — see §3 gotcha).
- [x] **[agent]** App: point `ClerkClient.defaultFrontendAPIBaseURLString` at
      the production Frontend API URL (e.g. `https://clerk.sentwise.ai`).
- [ ] **[agent]** Verify end-to-end on the deployed worker: email-code
      sign-in, `/v1/me`, one draft; after the owner allowlist step above,
      re-enable and verify Google sign-in via `/auth/callback`.
- [ ] **[owner+agent]** Lucius live-test payloads: the Clerk/managed live
      tests sign in against the instance the app compiles for — after the flip
      they need production-instance test users (or test mode consciously
      enabled) and updated `SENTWISE_LIVE_*` repo secrets before those payloads
      run again.
- [x] **`CLERK_AUTHORIZED_PARTIES` stays UNSET** until production native
      tokens are confirmed to carry a matching `azp` claim (S-L1 — setting it
      while tokens lack `azp` rejects every session).

## 2. Live Paddle

Vendor account fully verified 2026-09-12. Since the 2026-09-20 atomic
activation, app `PaddleConfig.active = production` (live client token + live
`pri_…` price ids) and worker `PADDLE_API_BASE = https://api.paddle.com`.
Findings A-I4/S-L2; item 91 portal-permission trap.

- [x] **[owner]** Paddle **live** dashboard: create the three products/prices
      exactly per `docs/tier-matrix.md` — **Starter $9/mo, Pro $19/mo,
      Unlimited $39/mo**, monthly recurring, USD. Record the three live
      `pri_…` ids.
- [x] **[owner]** Checkout settings → approved domains: add `sentwise.ai`
      (the WKWebView checkout's base origin).
- [x] **[owner]** Mint the live **API key** — MUST include
      `customer_portal_session.write` (item 91: without it portal-session
      creation fails silently and billing links regress to the email sign-in
      page). Record it for §3.
- [x] **[owner]** Create the live **client-side token** (frontend token) for
      Paddle.js.
- [x] **[owner]** Notifications → add webhook destination
      `https://sentwise-inference.sentwise-service.workers.dev/v1/paddle/webhook`
      subscribed to the same events as sandbox (subscription lifecycle +
      transaction.completed). Record the webhook **secret** for §3.
- [x] **[agent]** App: add `PaddleConfig.production` (live client token +
      three live price ids, same `checkoutOrigin`) and flip
      `PaddleConfig.active` to production.
- [x] **[agent]** Atomic paid-checkout activation, after approved domains and
      webhook setup are checked above: set Worker `PADDLE_API_BASE` →
      `https://api.paddle.com`, `wrangler secret put PADDLE_API_KEY` /
      `PADDLE_WEBHOOK_SECRET` with the live values (TTY), and flip
      `PaddleConfig.active` to production in the same release window.
- [x] **[agent]** Verify immediately after the atomic activation: live checkout
      overlay loads for each tier (billing guardrail: NO real purchase),
      webhook signature verifies on a Paddle test notification, portal link
      resolves. *(2026-09-21: webhook simulation verified — 200 with the live
      secret; checkout overlays verified 2026-09-21 — all three tiers loaded live prices in one session after the item 107 supersede fix; portal-link check deferred
      until the first real subscription exists — no Paddle customer yet.)* If verification fails, roll both Worker and app back to sandbox
      together.

## 3. Cloudflare secret hygiene (worker)

Secrets: `CLERK_SECRET_KEY`, `ANTHROPIC_API_KEY`, `ADMIN_TOKEN`,
`CF_ANALYTICS_API_TOKEN`, `PADDLE_WEBHOOK_SECRET`, `PADDLE_API_KEY`, optional
`ANALYTICS_HASH_KEY`. Findings S-I2 + "not assessed" items from the security
pass.

> **TTY gotcha:** `wrangler secret put` reads stdin; piped/non-interactive runs
> can silently store an EMPTY secret. Always run from a real terminal, and
> verify afterwards by exercising the code path (e.g. webhook 401→200), not
> just `wrangler secret list`.

- [ ] **[owner]** Rotate/confirm `ADMIN_TOKEN` with real entropy (e.g.
      `openssl rand -base64 32`).
- [ ] **[owner]** Decide `ANALYTICS_HASH_KEY` (S-I2): setting it upgrades the
      analytics pseudonym to keyed HMAC but breaks hash continuity with
      existing rows. Recommended: set it now, pre-launch, while history is
      worthless.
- [ ] **[owner]** Confirm `ANTHROPIC_API_KEY` is the production key under the
      zero-data-retention agreement.
- [ ] **[agent]** After all secrets: verify each path live (Clerk lookup,
      draft call, webhook verify, `/admin/margin` auth).
- [ ] **Decision recorded:** `ENFORCEMENT_MODE` stays `"soft"` for paid tiers;
      trials are hard-enforced in code regardless (S-M2 remediation). Flip to
      `"hard"` only by owner decision after 56b data.
- [ ] **[agent]** Per-tier limits already real (30/120/100000 monthly) — final
      sanity check against `docs/tier-matrix.md` at deploy time.

## 4. Sparkle update key (A-I3)

- [ ] **[owner]** Confirm the private EdDSA key exists offline (password
      manager / offline backup), not only in the build Mac's Keychain.
- [ ] **[agent]** Verify the shipped `SUPublicEDKey` in Info.plist matches the
      real keypair: `generate_keys -p` (prints the public key for the private
      key in the Keychain) must equal the plist value; then remove the stale
      "placeholder" doc comment.
- [ ] **[agent]** Verify the appcast feed URL is HTTPS and signed updates
      validate on a previous-version install (folds into the §6 clean-Mac
      Sparkle step).

## 5. feedback@sentwise.ai

- [ ] **[owner]** Create the mailbox (Google Workspace user or alias/group
      delivering to a monitored inbox) on the sentwise.ai domain.
- [ ] **[owner]** Send a test from an outside account; confirm receipt +
      SPF/DKIM pass.
- [ ] **[agent]** Confirm the app's "Report a Problem" (item 36) sends to
      exactly this address.

## 6. Clean-Mac verification run

- [ ] Fresh macOS user account or VM (never the maintainer's account).
- [ ] Browser-download DMG → Gatekeeper/notarization path → install.
- [ ] `brew install --cask` path.
- [ ] First-run onboarding: trial sign-in (production Clerk), Gmail app
      password connect, voice learn, first inbox draft, first transcript
      follow-up, approve via notification.
- [ ] Sparkle update from the previous version.
- [ ] Every friction point logged as a backlog item.

## 7. 1.0.0 release

- [ ] `/release-prep` 1.0.0; CHANGELOG written for humans.
- [ ] Cask + appcast verified from a machine that isn't the maintainer's.
- [ ] GitHub release notes link the quickstart (item 71).
- [ ] Public link goes out → close item 74.

---

*Parallel track (item 53, launch-NOT-blocking): Zoom transcript integration
builds alongside §§1–5; its Zoom Marketplace review is submitted as soon as the
integration demos end-to-end. 1.0 does not wait for it.*
