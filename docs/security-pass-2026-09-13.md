# Security pass — 2026-09-13 (backlog item 74)

Full read-only security audit of both repos ahead of 1.0: the app (`sentwise`, working tree at `6e1226f8`) and the Worker (`sentwise-service`, `main` at PR #16+#19+#20). Every finding below was verified against actual code (file:line) before being recorded; nothing here is speculative. Remediation is tracked in backlog items **94** (service hardening), **95** (app hardening), and **96** (local data purge); launch-blocking configuration steps live on item **74**'s cutover checklist.

## Findings — service (`sentwise-service`)

| # | Sev | Finding | Disposition |
|---|-----|---------|-------------|
| S-M1 | Medium | Clerk Backend API calls run **before** the DO rate-limit check on `POST /v1/draft` (`src/index.ts:165-183`), and `GET/DELETE /v1/me`, `/v1/interest`, and the Paddle endpoints do Clerk lookups with no limiter at all. One scripted trial account can exhaust Clerk's per-instance backend rate limits → `account_lookup_failed` for every user (whole-service DoS). `src/auth.ts:67-70` already carries the TODO for a lookup cache. | **Item 94** (pre-launch) |
| S-M2 | Medium | `ENFORCEMENT_MODE=soft` (`wrangler.jsonc:32`) means weekly draft/token caps never block; only 10 req/min + 55K tokens/request bound spend. A free throwaway trial account ≈ 14,400 drafts/day ≈ low-thousands USD/day of Anthropic spend. Was the deliberate 56b measure-first choice — unacceptable once the public link is out. | **Item 94** (hard enforcement for trials) + item 74 cutover config |
| S-L1 | Low | Clerk JWT verification doesn't pin `authorizedParties` (`src/auth.ts:53`); any session token of this instance is accepted regardless of client. Marginal while the native app is the only client. | Item 94 (cheap while in there) |
| S-L2 | Low | Deployed worker runs on the Clerk **dev** instance + Paddle **sandbox** (`wrangler.jsonc:25,41`). Known pre-launch state. | Item 74 cutover (already listed) |
| S-L3 | Low | Callback landing pages lack CSP/`frame-ancestors` (`src/callback.ts:57-65`). The page itself is injection-safe (verified), and the feared app-side login-CSRF is **blocked** — the app's Keychain flow-ID/state matching rejects forged callbacks (see app clean list). Residual is defense-in-depth headers only. | Item 94 |
| S-L4 | Low | Unknown Paddle `subscription.updated` statuses **fail open to `"active"`** (`src/paddle.ts:271-296`) — a future Paddle terminal status would leave entitlement active. | Item 94 |
| S-L5 | Low | Oversized/rejected drafts still consume the caller's own rate-limit slot. Self-DoS only. | Accepted |
| S-I1 | Info | Paddle checkout binding HMAC is stable per user, not transaction-scoped (`src/paddle-account.ts:86-92`). Safe today (server-minted transactions only); becomes relevant only if client-side Paddle.js checkout is ever added. | Noted; revisit if Paddle.js is adopted |
| S-I2 | Info | Analytics stores an unsalted SHA-256 of userId (`src/analytics.ts:19-22`) — deterministic pseudonym. Keyed HMAC would prevent offline re-identification. | Item 94 (cheap) |
| S-I3 | Info | `temperature` forwarded with type check only; Anthropic rejects bad values. | Accepted |
| S-I4 | Info | 405/401-vs-404 on `/admin/margin` reveals whether `ADMIN_TOKEN` is set. Trivial. | Accepted |

## Findings — app (`sentwise`)

| # | Sev | Finding | Disposition |
|---|-----|---------|-------------|
| A-M1 | Medium | Compiled-in Clerk **dev**-instance URL (`ClerkClient.swift:199`) — all production sign-ins would ride the dev instance. | Item 74 cutover (already listed: production Clerk instance) |
| A-M2 | Medium | Paddle checkout WKWebView has **no navigation policy** (`PaddleCheckoutSheet.swift:246-263`) — the in-app sheet (base URL spoofed to sentwise.ai) can be navigated anywhere by page script, making the trusted checkout surface a phishing canvas. Popups are already dropped; debug hooks correctly `#if DEBUG`-gated. | **Item 95** (pre-launch) |
| A-L1 | Low | `SENTWISE_INFERENCE_URL` env override honored in **release** builds (`ManagedInferenceClient.swift:12-20`) — a silent redirect knob for all managed drafting traffic (mail content + session JWT). Requires local code execution, but shouldn't ship. (`SENTWISE_IMAP_LOG` verified harmless — counts/mailbox names only.) | Item 95 |
| A-L2 | Low | Disconnect / remove-account leaves mail content on disk: `PendingDrafts.json` (full bodies), `ActivityEvents.json` (sender+subject), `VoiceProfile.json`, etc. survive `disconnectMail` / `removeSavedAccount` / `deleteManagedAccount`. Violates reasonable user expectation for a privacy-first product. | **Item 96** |
| A-L3 | Low | `signOut()` never revokes the Clerk session server-side (`ManagedAccountService.swift:175-203`) — an exfiltrated token stays valid until Clerk expiry. | Item 95 |
| A-L4 | Low | Keychain failure logs write the account email `privacy: .public` to the unified log (`KeychainStore.swift:63,78,82,105`); diagnostics bundle redaction covers it, local unified log does not. | Item 95 |
| A-L5 | Low | Subscription snapshot in plain UserDefaults is user-forgeable for the 7-day offline grace (`SubscriptionLicense.swift:162-197`). Server still gates all drafting — cosmetic/UI only. | Accepted |
| A-L6 | Low/Info | OpenRouter flow ID travels in the visible authorization URL — an attacker capturing the victim's browser URL mid-flow could complete provisioning with an attacker account. Purely-local injection is blocked (PKCE verifier + flow-ID match, verified). Inherent to OpenRouter's flow. | Accepted (note) |
| A-I1 | Info | ATS `NSAllowsLocalNetworking=true` — scoped, needed for local Ollama. | Accepted |
| A-I2 | Info | App is **not sandboxed**; hardened runtime is ON, no library-validation disable. Typical for a Sparkle menu-bar app; item 60 tracks the sandboxing question. | Conscious 1.0 decision: ship unsandboxed (item 60 unchanged) |
| A-I3 | Info | `SUPublicEDKey` present + HTTPS feed + no feed-override code, but a stale doc comment calls the key a placeholder — confirm the plist key matches the real release keypair and the private key is held offline. | Item 74 checklist (owner verify) |
| A-I4 | Info | `PaddleConfig.active = sandbox` with public test token/price ids. | Item 74 cutover (already listed) |

## Verified clean (auditable)

**Service**: full route-auth enumeration (only healthz, the two exact-match callback pages, the signature-authed webhook, and the token-authed admin route are unauthenticated); Paddle webhook HMAC timing-safe with ±300s tolerance, 128KB pre-verification cap, replay/idempotency guards, and custom_data forgery blocked (victim-email checkout attribution refused); no IDOR on any money endpoint (all entity ids derived from the authenticated user's own metadata); plan/price changes locked to the server-side tier map; quota DO addressable only via JWT-verified `sub`, transactional, race-free; Anthropic proxy pinned to one endpoint + one allow-listed model, caps enforced server-side, upstream errors never forwarded verbatim; **no body logging on any path including errors** (CI-guarded); admin comparison timing-safe; no CORS (correct for a native-app API); `npm audit` 0 vulnerabilities; single runtime dep; no secrets in repo or last 200 commits.

**App**: every secret in Keychain (`AfterFirstUnlockThisDeviceOnly`, never synced) — none in UserDefaults/plists/files; all 121 Logger sites clean of content/credentials; item-36 diagnostics bundle fully passes `DiagnosticsRedactor`; `sentwise://` callbacks state/nonce-gated via Keychain flow IDs (forged/stateless callbacks cannot complete or swap accounts — this also closes the service audit's L3 login-CSRF question); IMAP/SMTP implicit TLS with full verification + SNI in all 8 pipeline builders, zero trust overrides; Sparkle HTTPS feed + EdDSA, no overrides; hunt mode is a fixtures-only demo mode with no enforcement bypass; no committed credentials (live tests use `SENTWISE_LIVE_*` env only); item-83 privacy stance verified (codes/hashes only; deny free-text never leaves the local store).

**Not assessed** (out of scope/reach): live secret hygiene on Cloudflare (empty-secret TTY gotcha), `ADMIN_TOKEN` entropy, Clerk/Paddle dashboard configuration, real `SUPublicEDKey`↔keypair match, `paddle-entitlement.ts` internal ledger arithmetic (trust boundaries verified; residual risk is bookkeeping, not authorization), third-party dependency internals.
