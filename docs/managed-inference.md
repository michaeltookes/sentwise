# Managed inference (item 56a)

Managed inference lets a signed-in Sentwise user draft email **without touching
an API key**. Drafting requests go through a stateless, zero-retention proxy
(`sentwise-service`) that authenticates the user's account and forwards to the
model provider under zero-data-retention terms. This is the default for new
installs; bring-your-own-provider remains the power/privacy path (item 59).

This document covers the app side. The proxy lives in its own public repo,
[`sentwise-service`](https://github.com/michaeltookes/sentwise-service), whose
README explains the no-storage/no-logging design.

## Pieces

| Piece | File | Role |
|---|---|---|
| Provider case | `Services/LLM/LLMTypes.swift` (`LLMProviderKind.managed`) | Default provider; `requiresAPIKey == false`, `supportsCustomBaseURL == false` |
| Client | `Services/LLM/ManagedInferenceClient.swift` | `LLMClient` calling `POST /v1/draft` with a Clerk session token |
| Session provider | `Services/Clerk/ManagedAccountService.swift` | Mints short-lived session tokens on demand; the `ManagedSessionProviding` behind `LLMService` |
| Sign-in | `Services/Clerk/ClerkClient.swift` | Native Clerk Frontend-API email-code flow |
| App state | `App/AppState+ManagedAccount.swift` | Sign-in/out actions + the 14→15 settings migration |
| UI | `Views/AIProviderControls.swift`, `Views/AIProviderSettingsView.swift` | Managed-first card + BYO behind a disclosure |

## Where the endpoint comes from

`ManagedInference.baseURL` is a compile-time constant
(`https://sentwise-inference.sentwise-service.workers.dev`) with a
`SENTWISE_INFERENCE_URL` environment override for dev/staging and the env-gated
live test.

## Trial

The trial is enforced **server-side** (14 days, full-featured). The Worker
stamps `trialStartedAt` into the account on the first authenticated draft and
returns a `402`-class structured error after expiry. The app maps that to
`LLMError.managedTrialExpired` and shows the plain message — never a raw HTTP
status.

## Sign-in: why the native Clerk Frontend API (not the clerk-ios SDK)

The locked decision was to use the clerk-ios SDK **if** it supports macOS and
builds cleanly via SPM, otherwise a browser hand-off or the Frontend API
directly. We chose to **implement Clerk's Frontend API email-code flow natively**
(no SDK). Rationale:

- **Zero new dependencies.** clerk-ios *does* declare `.macOS(.v14)`, but
  adopting it means adding a remote SPM dependency (and its transitive deps) to
  the Xcode project, and its prebuilt UI components are iOS-oriented and don't
  fit a macOS menu-bar app. A hand-rolled client adds nothing to a local-first,
  minimal-surface app.
- **Testability.** The flow is fully unit-tested against a fake transport
  (`ClerkClientTests`, `ManagedAccountServiceTests`), matching the app's existing
  LLM/IMAP client-testing pattern.
- **No URL scheme needed.** The app has no registered custom URL scheme, so a
  hosted-portal browser hand-off would have required net-new Info.plist wiring
  and a token hand-back the hosted portal doesn't natively provide for native
  apps.

### The native mechanism

Clerk's native (non-browser) auth uses an `Authorization: Bearer <clientToken>`
header on every Frontend-API request (empty on the first call). Clerk returns a
rotated client (device) token in the `Authorization` response header, which we
store in the Keychain and echo on the next request. No `Origin` header is sent
(that would put Clerk into browser/cookie mode). Requests are marked native with
`?_is_native=1`.

The email-code flow:

1. `POST /v1/client/sign_ins` with `identifier=<email>` → sign-in id +
   `email_address_id`.
2. `POST /v1/client/sign_ins/{id}/prepare_first_factor` (`strategy=email_code`)
   → sends the code email.
3. `POST /v1/client/sign_ins/{id}/attempt_first_factor` (`strategy=email_code&code=…`)
   → `status=complete` + `created_session_id`.
4. `POST /v1/client/sessions/{session_id}/tokens` → `{ "jwt": … }`, the
   short-lived session token the Worker verifies. Refreshed by calling again;
   `ManagedInferenceClient` mints a fresh one per draft.

The Keychain holds the device token (`managed.clientToken`) and session id
(`managed.sessionID`); the account email is stored in (non-secret) settings for
the "Connected as …" display.

## Google sign-in via Clerk OAuth (item 59)

Google is offered as the one-click sign-in alongside email code. It uses Clerk's
Frontend-API OAuth flow, driven natively (no clerk-ios SDK), and hands off to the
system browser through a registered custom URL scheme.

Flow:

1. `POST /v1/client/sign_ins` with `strategy=oauth_google` and
   `redirect_url=https://sentwise-inference.sentwise-service.workers.dev/auth/callback` → Clerk returns the sign-in with
   `first_factor_verification.external_verification_redirect_url` (a hosted URL).
2. The app opens that URL in the default browser (`NSWorkspace.open`). The user
   authenticates with Google; Clerk finishes the external handshake.
3. Clerk redirects the browser to the Worker's `/auth/callback?rotating_token_nonce=…` landing page ("You're signed in — you can close this tab"), which forwards to `sentwise://oauth-callback?rotating_token_nonce=…`. Redirecting straight to the custom scheme left the Google tab spinning forever (observed 2026-08-21). The Worker forwards only the allow-listed parameter and stores/logs nothing.
   `AppDelegate.application(_:open:)` routes it to `AppState.handleIncomingURL`,
   which parses it with `SentwiseURLCallback` and calls
   `ManagedAccountService.completeGoogleSignIn(rotatingTokenNonce:)`.
4. Completion reloads the sign-in with the nonce
   (`POST /v1/client/sign_ins/{id}?rotating_token_nonce=…&_is_native=1`), expects
   `status=complete` + `created_session_id`, mints a session token, and stores the
   credentials exactly like the email-code path. The reloaded resource's
   `identifier` (email) is used for the "Connected as …" display.

The pieces: `ClerkClient.startOAuthSignIn` / `completeOAuthSignIn`,
`ManagedAccountService+OAuth.swift`, `AppState+ManagedOAuth.swift`,
`SentwiseURLCallback`, and the `CFBundleURLTypes` entry in `Info.plist`.

### Clerk dashboard prerequisite (owner action required)

Native OAuth is **not verified live yet** (needs the owner + a browser). Before
it can work, the Clerk dashboard must be configured:

- **Enable the Google social connection** (User & Authentication → Social
  Connections → Google). For the dev instance, Clerk's shared dev credentials are
  fine; production needs a Google OAuth client.
- **Allow the redirect.** Add `https://sentwise-inference.sentwise-service.workers.dev/auth/callback` to the
  instance's allowed redirect URLs / allowlist for native redirects (Clerk calls
  this the redirect allowlist for the OAuth `redirect_url`). Without it Clerk
  rejects the `redirect_url` on the `sign_ins` create call.

Once configured, exercise the full flow once and record the result here (as the
email-code flow was recorded under **Live verification** above).

## OpenRouter one-click BYO (item 59)

The featured bring-your-own path. `OpenRouterKeyProvisioner` runs OpenRouter's
PKCE flow so the user never copies a key:

1. `AppState.beginOpenRouterProvisioning` mints a PKCE pair (`PKCEGenerator`),
   stores the verifier in the Keychain (`openRouter.pkceVerifier`), and opens
   `https://openrouter.ai/auth?callback_url=https://sentwise-inference.sentwise-service.workers.dev/openrouter/callback&code_challenge=…&code_challenge_method=S256`.
2. OpenRouter redirects the browser to the Worker's `/openrouter/callback?code=…` landing page, which forwards to `sentwise://openrouter-callback?code=…`.
   `handleOpenRouterCallback` exchanges the code + verifier at
   `POST https://openrouter.ai/api/v1/auth/keys` for an API key.
3. The key is stored as the **OpenAI-compatible** provider's key, with the base
   URL set to `https://openrouter.ai/api/v1` and a default model of
   `openai/gpt-4o-mini`, then marked connected. Switching back to managed is one
   click.

No dashboard configuration is required for OpenRouter beyond the user having (or
creating) an OpenRouter account during the browser step. Live verification of the
round-trip is **pending** (needs the owner + a browser + an OpenRouter account).

## URL scheme security

Any app on the machine can register and claim the `sentwise://` scheme, so an
incoming callback URL is treated as untrusted input. It cannot complete either
flow on its own:

- **Clerk OAuth:** the `rotating_token_nonce` is only meaningful against the
  in-memory pending sign-in handle (`ManagedAccountService.pendingOAuthSignIn`),
  which exists only between `startGoogleSignIn` and its completion and is bound to
  a specific `sign_in` id and device (client) token. A callback that arrives with
  no pending sign-in is rejected (`malformedResponse("no oauth sign-in in
  progress")`); a forged nonce fails Clerk's server-side reload.
- **OpenRouter:** the redirect `code` is useless without the PKCE **verifier**,
  which never leaves the Keychain (`openRouter.pkceVerifier`) and is consumed on
  first use. Without it the exchange isn't even attempted.

`SentwiseURLCallback` additionally rejects any foreign scheme, unknown host, or
missing/empty parameter, and `handleIncomingURL` ignores all deep links during a
Prowl hunt. Universal Links (an `applinks:` associated-domain entitlement) are the
future hardening if we ever want the OS to guarantee only Sentwise receives these
redirects; the custom scheme is sufficient today because neither flow can be
completed by a hijacked callback.

## Scope notes / live verification (56a)

- **Google sign-in was deferred out of 56a and delivered in item 59** (above).
  Email code remains the other enabled method.
- The native flow is implemented to Clerk's Frontend-API spec. It is fully
  unit-tested, but a real end-to-end sign-in against the live dev instance
  (which needs an email inbox for the code) has **not** been exercised in CI.
  The env-gated live test (`ManagedInferenceLiveTests`) verifies the **Worker**
  (`/v1/me`, `/v1/draft`) with a manually supplied session token via
  `SENTWISE_LIVE_CLERK_SESSION_TOKEN` + `SENTWISE_INFERENCE_URL`.

## Settings migration (14 → 15)

On first launch at schema 15, an install with **no configured BYO provider** (no
stored API key and no verified model) moves to `.managed`. A configured BYO user
keeps their provider. Fresh installs default to `.managed` directly. The
migration is gated on the original schema version so it runs once
(`AppState.migratedManagedInferenceSettings`).

## Metering (56b) — app side

The Worker meters a **weekly draft allotment** that resets weekly, then
pay-per-use overage (the purchase flow is 56c). Under the hood it counts tokens
with a per-request safety cap; the UI presents a friendly unit (**drafts**).
Enforcement is **soft** while dogfooding — drafting is never blocked; the
hard-block + real "buy more" ship with 56c. This repo implements only the
app-side surfacing + alerts (service half lives in `sentwise-service`).

### Quota model (`ManagedQuota`, `Services/LLM/ManagedQuota.swift`)

A `Codable, Sendable, Equatable` value type decoded from the `quota` object on
**both** `GET /v1/me` and every `POST /v1/draft` response:

```
{ "unit":"drafts", "used":Int, "limit":Int, "remaining":Int,
  "resetsAt":ISO8601, "tokensUsed":Int, "tokenLimit":Int,
  "enforcement":"soft"|"hard", "extraPurchased":Int }
```

`quota` is **optional** everywhere it's decoded, so an older Worker build that
omits it still parses. Decoding is lenient: missing numbers default to 0,
`remaining` falls back to `limit − used`, an unknown/absent `enforcement`
defaults to `soft`, and `resetsAt` accepts the fractional-seconds ISO-8601
variant (absent → `.distantPast`, treated as "reset unknown" by the display).

### Refresh points & flow

- **`/v1/draft`**: `ManagedInferenceClient` decodes `quota` into
  `LLMResponse.quota`; `LLMService.complete` reports it to a
  `ManagedQuotaReporting` sink.
- **`/v1/me`**: `LLMService.fetchManagedQuota()` (via
  `ManagedInferenceClient.fetchAccountQuota()`, an authenticated GET) is called
  at **app launch** (`AppDelegate`), **sign-in**
  (`finalizeManagedSignIn`), and when the **AI Provider settings pane opens**
  (`ManagedUsageView.task`).
- Both funnel through `AppState.ingestManagedQuota` (`AppState+Quota.swift`),
  which mirrors the latest quota into the `@Published var managedQuota` and runs
  the alert logic. The off-main → main hop is a `ManagedQuotaRelay`.

### Settings display (`Views/ManagedUsageView.swift`)

In the Sentwise AI section when signed in: **"N of M drafts used this week ·
resets \<weekday, time\>"** with a `ProgressView`, a subdued "Extra usage
purchased: X" line only when `extraPurchased > 0`, a **"Buy more usage"**
placeholder (56c wires purchase) shown when at/over limit, and the
**own-key valve** pointing at the BYO section below (item 59). Hidden gracefully
when `managedQuota == nil`. AX ids: `managedUsageSection`, `managedUsageSummary`,
`managedUsageProgress`, `managedExtraPurchased`, `buyMoreUsage`,
`managedOwnKeyValve`.

### Error mapping (`LLMError` + `AppState.llmMessage`)

| Worker response | `LLMError` case | User copy |
| --- | --- | --- |
| `429` `rate_limited` (+`retryAfterSeconds`, `Retry-After` header) | `.managedRateLimited(retryAfter:)` | "You're drafting faster than Sentwise allows — try again in N seconds." |
| `429` `quota_exceeded` (+`resetsAt`, hard mode only) | `.managedQuotaExceeded(resetsAt:)` | Explains the weekly reset, "Buy more usage in Settings → AI, or use your own key for unlimited drafting." |
| `413` `request_too_large` | `.managedRequestTooLarge` | Suggests trimming the transcript/thread. |

Body `retryAfterSeconds` takes precedence over the `Retry-After` header.
`ResilienceClassifier` treats rate-limit as **transient** and carries the parsed
delay into `RetryRunner`, while quota-exceeded / too-large remain **permanent**.
Existing `402`/`trial_expired` and `401` handling is unchanged.

### Usage alerts (50 / 75 / 100 %)

`UsageAlertEvaluator` (`Services/UsageAlert.swift`) is pure decision logic: given
the latest quota and the previously-persisted `UsageAlertState`, it returns the
thresholds to fire **now**. A threshold fires **once per managed account and
weekly window**; fired thresholds are persisted by hashed account key plus
`resetsAt` (`UserDefaultsUsageAlertStore`) so a relaunch never re-fires for the
same account, while an account change or changed `resetsAt` resets the fired set.
Alerts post via `NotificationService.notifyUsageAlert` under a distinct
`USAGE_ALERT` category whose **Open** action routes to Settings → AI Provider
(not Review Drafts), respecting the existing notification-permission handling.
The 100% copy in soft mode says drafting continues and points to buying extra
usage / own key. Alerts are suppressed in Prowl hunt mode (the display value
still updates).

### Prowl hunt mode

`StubManagedInferenceClient` returns a plausible fixed `quota`
(`StubManagedInferenceClient.stubbedQuota`) with zero network, and
`LLMService.fetchManagedQuota()` returns the same stub in hunt mode, so the pane
renders deterministically. `ingestManagedQuota` skips alert scheduling under
`ProwlHuntRuntime.current.isEnabled`, so hunts stay side-effect free.

## Account & subscription (item 73)

The **Subscription** tab of Settings (`SettingsTab.subscription`, after "AI") is
the Sentwise-account home: account email, plan / trial / renewal, weekly usage
(reused from `ManagedUsageView`), a manage-billing entry point, sign-out, and a
guarded delete-account flow. It is distinct from the **Account** tab, which is
the *mailbox* (IMAP) account. The AI tab keeps only a one-line
"Account, usage, and plan details are under Subscription" link
(`openSubscriptionFromAI`) that switches tabs via `openSettingsHandler`; the
usage bar is never rendered in two places.

### Status shape (`GET /v1/me`)

`ManagedAccountStatus` (`Services/LLM/ManagedQuota.swift`) is `Codable` and
decoded directly by `ManagedInferenceClient.fetchAccountStatus`. It carries
`userId`, `email`, `trial`, `quota` (56b), and `subscription`:

```
{ "userId": String,
  "email": String,
  "trial": { "startedAt": ISO8601, "endsAt": ISO8601, "active": Bool },
  "quota": { …56b… },
  "subscription": { "plan": "trial"|"individual"|"team"|"none",
                    "status": "trialing"|"active"|"past_due"|"canceled"|"lapsed",
                    "renewsAt": ISO8601|null,
                    "manageBillingUrl": String|null } }
```

`trial`, `quota`, and `subscription` are each **optional** when decoding, so an
older Worker that omits any of them still parses. A present-but-malformed `quota`
(wrong JSON type) still fails decoding — only omitted blocks decode to nil.
`ManagedSubscription.Plan` and `.Status` both fall back to `.unknown` for any
unrecognised raw value, so a new server-side plan/status never breaks decoding.
Dates parse leniently via `ManagedQuotaDate` (fractional-seconds tolerant).

### Derivation (pre-56c)

Until checkout (56c) ships, the Worker derives `subscription` from the trial
(`plan: "trial"`, `status: "trialing"|"lapsed"`, `manageBillingUrl: null`). When
the whole `subscription` block is absent (older Worker), the app derives an
effective `(plan, status)` from the `trial` block in `SubscriptionPaneModel`
(`Views/SubscriptionPresentation.swift`): an active trial → trialing, otherwise
lapsed. `SubscriptionPaneModel` is the pure, testable mapping from status → the
plan line, an optional detail/explanation line, and an `isProblemState` flag
(past-due / canceled / lapsed) that surfaces the "use your own AI key" fallback.
Trial days remaining round up (any time left reads as ≥ "1 day left") and clamp
at 0 ("Trial ended").

### Manage billing (stub until 56c)

The "Manage billing" button (`manageBilling`) opens
`subscription.manageBillingUrl` when present; while it is `null` (pre-56c) the
button is disabled with the caption "Billing management arrives with checkout."
Lapsed / past-due / canceled states render an explanatory line and a link to the
AI tab's "Use your own AI" section, because managed drafting pauses in those
states while own-key drafting still works.

### Delete account (`DELETE /v1/me`)

`ManagedInferenceClient.deleteAccount` (exposed through
`LLMProviding.deleteManagedAccount` / `LLMService`) sends an authenticated
`DELETE /v1/me`. `204` → success (the Worker removed the Clerk user and
server-side usage counters); `401` → `LLMError.managedNotSignedIn`; `502
account_deletion_failed` → `LLMError.managedAccountDeletionFailed` (kept account,
retryable). The pane's confirmation sheet (`DeleteAccountSheet`) states exactly
what is removed (Sentwise account + server-side usage counters) and what is not
(mail, voice profile, drafts, and settings on this Mac), and gates the action
behind typing `DELETE`. On `204`, `AppState.deleteManagedAccount` clears the
managed credentials locally (`ManagedAccountService.signOut` semantics), resets
to the managed-signed-out state, and flips `didDeleteManagedAccount` for the
brief signed-out confirmation. Local data is untouched. On failure the account is
kept and the mapped message is shown.

### Refresh points

`AppState.managedAccountStatus` (`@Published`) is populated by
`refreshManagedQuota`, which now mirrors the **full** status (email/trial/
subscription/quota) from a single `/v1/me` fetch. It runs at **launch**
(`AppDelegate`), on **sign-in** (`finalizeManagedSignIn`), and on **tab open**
(the Subscription pane's outer-container `.task`, not inside an `if let`, so it
runs even while the status is unknown). `ManagedUsageView` no longer fetches
itself, avoiding a double `/v1/me` on tab open. A usage-threshold alert's Open
action now routes to the Subscription tab (usage moved there from AI).

### Prowl hunt mode

`StubManagedInferenceClient.stubbedAccountStatus` returns a fixed active
Individual status (no billing URL) with zero network, and
`LLMService.fetchManagedAccountStatus()` returns it in hunt mode so the pane
renders deterministically. Delete is a zero-network no-op
(`AppState.deleteManagedAccount(isHuntMode:)` returns success without teardown),
and the `"delete"`/`"Delete"` forbidden selectors in `.prowl/config.yml` already
block activating the destructive controls while the pane is still walkable.

## Workspace app-password guidance (item 75)

The flagship ICP works on a company **Google Workspace** account, and many
Workspace admins turn off app passwords, disable IMAP, or enforce a
security-key/web-login policy — each makes the IMAP + app-password path (item 32)
fail with a message users read as "Sentwise is broken". `WorkspaceAuthFailure`
(`App/WorkspaceAuthFailure.swift`) is a **pure classifier** over the server text in
`MailError.authenticationFailed`, the address's domain, and the IMAP host. It
extends the item-43 `CredentialGuidance` pattern rather than forking it:
`CredentialGuidance` explains how to *get* the credential; `WorkspaceAuthFailure`
explains why a correct-looking credential is being *rejected by policy*.

Classification (case-insensitive, **Google host only** — detected via
`EmailProviderKind.forHost == .gmail`; any other host → `.none`):

| Class | Server text it matches | Domain rule |
| --- | --- | --- |
| `appPasswordRejectedWorkspace` | `[AUTHENTICATIONFAILED] Invalid credentials` | **custom domain only** — indistinguishable from a typo, so consumer `gmail.com`/`googlemail.com` fall back to `.none` (the item-43 typo/2-Step guidance) |
| `imapDisabled` | `IMAP access is disabled`, or `[UNAVAILABLE]` mentioning IMAP | any Google host (admin policy on Workspace, or the user's own Gmail setting) |
| `webLoginRequired` | `Web login required`, or the `support.google.com/mail/accounts/answer/78754` URL | any Google host |
| `.none` | anything else, or a non-Google host | — |

`WorkspaceAuthGuidance.make(for:isCustomDomain:)` renders the connect-screen copy:
a plain-language headline, one line making clear it's an account/admin policy (not
a Sentwise bug), concrete options (ask the admin to allow app passwords / enable
IMAP; use a personal account meanwhile), a **copyable one-line "Ask your admin"
message** (fixed wording naming both levers + Google's article
`support.google.com/accounts/answer/185833`), and a Google support link. `imapDisabled`
and `webLoginRequired` frame admin-vs-personal from `isCustomDomain`; a personal
Gmail account gets account/security/app-password troubleshooting and no admin ask,
because Gmail no longer exposes a personal-account IMAP enable/disable toggle.

Surfaced by `WorkspaceAuthGuidanceView` in both onboarding
(`OnboardingAccountStep`) and Settings (`EmailAccountSettingsView`), wherever
`CredentialGuidance` renders today. `AppState.classifyWorkspaceAuthFailure` runs on
a failed connect and, for a recognized class, records a metadata-only activity
entry (`ActivityEventKind.workspaceAuthGuidance`, `detail` = the class name only —
never the email, server text, or credential) so the maintainer can see how often
launch users hit it while dogfooding. **AX ids** for Prowl: `workspaceGuidance`,
`askAdminCopy`, `oauthInterestButton`, `oauthInterestConfirmation`.

## "Sign in with Google" interest capture (item 75)

When an IMAP connect fails on a Google host because a Workspace admin has disabled
app passwords or IMAP (see [Workspace app-password guidance](#workspace-app-password-guidance-item-75)),
the guidance block offers **"Notify me when Sign in with Google is available"** — a
demand signal for reviving the parked bundled-OAuth + CASA path (item 3).

- **Client:** `Services/GoogleOAuthInterest.swift` → `GoogleOAuthInterestClient`
  calls `POST /v1/interest` with body `{"topic":"google-oauth"}` under a fresh
  Clerk session token (Bearer), exactly like `POST /v1/draft`. Expects **`204 No
  Content`** on success; **`401`** (unauth) maps to `LLMError.managedNotSignedIn`
  and invalidates the session; other non-2xx statuses reuse
  `ManagedInferenceClient.mapError` (same error-envelope shape as the other
  routes). Endpoint: `ManagedInference.interestEndpoint` (`…/v1/interest`, honoring
  the `SENTWISE_INFERENCE_URL` override).
- **Consent:** clicking the button is an explicit user action — consent — but
  nothing is ever sent without the click, matching the opt-in telemetry rule. The
  button is **hidden unless a managed account is signed in** (`isManagedSignedIn`;
  the per-account demand signal needs an account, and mailbox connect can precede
  sign-in only in edge flows).
- **Don't re-offer:** on success the confirmation ("You're on the list") is
  persisted locally per hashed managed account
  (`UserDefaultsGoogleOAuthInterestStore`, keyed by `ManagedUsageAccountKey`, never
  the email), so the button isn't shown again. `AppState.refreshGoogleOAuthInterestState`
  recomputes it at launch and on sign-in.
- **Prowl hunt mode:** `AppState.registerGoogleOAuthInterest(isHuntMode:)` is a
  no-op stub — it never touches the network. The guidance block itself renders from
  injected state with zero network (a pure `WorkspaceAuthFailure` classification),
  so hunts never reach a live call.

## Prowl hunt mode

`LLMService` returns a `StubManagedInferenceClient` (deterministic canned
response, zero network) whenever `ProwlHuntRuntime.current.isEnabled`, so drafting
stays offline-safe.

**Sign-in and provisioning are functional but fully offline in hunt mode
(item 70).** Rather than being disabled, the item-59 flows run through a
deterministic in-memory fake so accessibility hunts can drive them end-to-end
without ever reaching Clerk/OpenRouter/Anthropic or opening a browser:

- `startManagedSignIn` / `verifyManagedCode` (`AppState+ManagedAccount.swift`)
  advance to the code stage and complete to the signed-in fixture account.
- `startManagedGoogleSignIn` (`AppState+ManagedOAuth.swift`) shows the
  "finish in your browser" panel without opening a browser;
  `completeManagedGoogleSignInForHunt` (`AppState+ProwlHuntAuth.swift`) finishes it.
- `completeOpenRouterProvisioningForHunt` (`AppState+ProwlHuntAuth.swift`)
  activates a fake OpenAI-compatible/OpenRouter provider with no key exchange.

Every fake is strictly guarded on `ProwlHuntRuntime.current.isEnabled` (injectable
for unit tests — `AppStateProwlHuntAuthTests`), so the production paths are
unchanged. The controls carry `accessibilityIdentifier`s documented in
`.prowl/README.md`; `forbiddenSelectors` in `.prowl/config.yml` was relaxed so the
sign-in/provider hunts can activate exactly those controls while mail dispatch,
draft mutation, LLM generation, mailbox search, and system toggles stay forbidden.

## Live end-to-end sign-in test (env-gated)

`ClerkLiveSignInTests` exercises the **real `ClerkClient`** against the live Clerk
dev instance (`peaceful-eel-9660.clerk.accounts.dev`) via the Frontend API. It
**skips by default** and only runs when `SENTWISE_LIVE_CLERK_TEST` is set, so CI
and normal `xcodebuild test` runs stay offline.

It uses **Clerk's test-email mechanism**
([docs](https://clerk.com/docs/testing/test-emails-and-phones)): any address with
the **`+clerk_test`** subaddress is a test address (no email is sent), and the
**fixed code `424242`** always verifies it. This needs **no real inbox** and **no
Clerk secret key** — the Frontend API authenticates with the public instance, like
the app's native flow. The test creates the sign-in (falling back to sign-up for a
new test email, which `ClerkClient` handles), attempts the test code, asserts a
completed session, and mints a session token.

Run it:

```bash
SENTWISE_LIVE_CLERK_TEST=1 xcodebuild test \
  -project Sentwise/Sentwise.xcodeproj -scheme Sentwise \
  -only-testing:SentwiseTests/ClerkLiveSignInTests \
  -derivedDataPath <scratch> CODE_SIGNING_ALLOWED=NO
```

Prerequisite (already configured on the dev instance): Email address (verification
code) on, Password off, Organizations off.

**Google and OpenRouter are not tested live** — their browser round-trips are not
automatable from a headless test. Google/OpenRouter are covered by the offline
hunt fakes (above) and their unit tests (`ManagedAccountServiceOAuthTests`,
`OpenRouterKeyProvisionerTests`).

## Live verification

- **2026-08-20/21:** owner signed up via the native email-code flow against the real Clerk dev instance (Clerk's *Password* requirement had to be turned off in the dashboard first — `required_fields` included `password`, which the passwordless flow can never satisfy), switched the active provider to Sentwise AI, and generated a draft from Review Drafts. `wrangler tail` showed `POST /v1/draft → 200`, outcome `ok`, ~3.2 s wall time, no exceptions, no logs. Clerk dashboard prerequisite: **Email address (verification code) on, Password off, Organizations off.**

## Service repo CI/CD (added 2026-08-21)

`sentwise-service` `main` is the source of truth for the deployed Worker. On every push/PR, CI runs the privacy guard (no `console.*` in `src/`), ESLint + Prettier, typecheck, vitest, and `npm audit --audit-level=high`; Dependabot watches npm and GitHub Actions weekly; Claude code review runs on PRs. Merges to `main` trigger the **Deploy** workflow, which is gated by the `production` environment (required reviewer: the owner; `main` only) and ends with a `/healthz` smoke check. Secrets live as repository secrets (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `CLAUDE_CODE_OAUTH_TOKEN`); the Worker's own `CLERK_SECRET_KEY` / `ANTHROPIC_API_KEY` remain Cloudflare secrets set via `wrangler secret put`. First gated deploy: PR #1 → `0f73d51`.

### Live Clerk sign-in — confirmed 2026-08-21

`ClerkLiveSignInTests.testLiveEmailCodeSignInCompletesSession` was run against the real
`peaceful-eel-9660.clerk.accounts.dev` dev instance and **passed**: it created a sign-up for
`sentwise-live+clerk_test@sentwise.ai` (Clerk test address — no email sent), verified with the
universal test code `424242`, and got a completed session with a minted token. This exercises the
real `ClerkClient` including the sign-up fallback and native token rotation.

Running it: the gate reads `SENTWISE_LIVE_CLERK_TEST=1` from the test process environment. A plain
shell `env` (or `TEST_RUNNER_…`) does **not** propagate into a macOS app-hosted unit test via
`xcodebuild test`; set it in the scheme/test-plan test-action environment, or inject it into the
`.xctestrun` (`build-for-testing` → set `SentwiseTests.EnvironmentVariables.SENTWISE_LIVE_CLERK_TEST=1`
→ `test-without-building -destination 'platform=macOS'`). Google/OpenRouter remain browser
round-trips and are not automatable as live tests — they are covered by the deterministic hunt-mode
fake and unit tests instead.
