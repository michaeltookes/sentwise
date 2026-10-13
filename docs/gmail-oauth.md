# Sign in with Google for Gmail (item 104)

Sentwise can connect a Gmail or Google Workspace mailbox with one click: the
user approves Google's consent screen in their browser, and Sentwise reads and
sends mail over IMAP/SMTP using **XOAUTH2** with a short-lived access token. No
2-Step Verification prerequisite, no 16-character app password to generate and
paste, and it works for Workspace users whose admin disabled app passwords
(item 75's gap).

The app-password path (item 32) is unchanged. It stays the documented fallback
for Gmail and the **only** path for every other provider (Yahoo, iCloud, AOL,
AT&T, custom IMAP hosts).

**Tier placement:** available on **all plan tiers**. No tier gate is applied in
code. The owner has not confirmed this yet (item 104); gating it later would be
a small change in `AppState.isGoogleSignInAvailable`.

---

## How it works

| Piece | Where |
|---|---|
| PKCE loopback flow (browser → `http://127.0.0.1:<random port>` → code exchange) | `GmailAuthCoordinator`, `LoopbackRedirectListener`, `OAuthTokenService` |
| One bundled client, read from build configuration | `GoogleOAuthClientConfiguration` (Info.plist ← `Config/GoogleOAuth.xcconfig`) |
| Per-account token storage in the Keychain (`gmail.oauthToken.<email>`) | `GmailAuthStore` via `SecretStore` (the isolated test service under test, item 115) |
| Observable progress + cancel for the UI | `GoogleMailAuthService` (`GmailAuthPhase`: idle → awaitingBrowser → exchangingCode → idle / failed) |
| XOAUTH2 for every IMAP/SMTP session | `GoogleOAuthMailProvider` (app) + `MailAuthentication.xoauth2` / `XOAuth2` (SentwiseMail) |
| Connect / disconnect / switch / remove | `AppState+GoogleSignIn.swift` |
| UI: Google leads, app password is the fallback | `GoogleOrAppPasswordConnect` in onboarding and Settings → Email Account |

**Scopes requested:** `https://mail.google.com/` (restricted, required for
IMAP/SMTP XOAUTH2) plus `openid email` (non-sensitive, used only to read which
address the user authorized from the ID token, so they never type it). Only the
mail scope is enforced on the granted token.

**Credential slot marker.** Every connected mailbox already owns a per-account
Keychain slot (`mail.appPassword.<email>`, item 48) that account switching,
removal, rollback, and the multi-account watchers (item 99) carry around. A
Google mailbox stores the fixed, non-secret marker `sentwise-google-oauth:v1`
there. Before each IMAP/SMTP session, `GoogleOAuthMailProvider` replaces the
marker with a valid access token (refreshing it if it has expired, one refresh
per mailbox at a time). The marker can never authenticate on its own.

**Lifecycle.**
- Sign in: browser consent → token stored under the authorized address →
  verified and adopted through the same `testConnection(with:)` path as an app
  password. If verification fails, the new grant is deleted. Nothing is left
  behind for a mailbox that did not connect.
- Disconnect, remove a saved account, or switch that mailbox to an app password:
  the token is deleted and the grant is revoked at Google (best effort; a
  revocation network failure never blocks the local removal).
- Revoked or expired grant (`invalid_grant`): the session fails with "Google
  sign-in expired or was revoked — sign in with Google again…". Google failures
  never show the app-password or Workspace-admin guidance.
- Token endpoint unreachable: reported as a transient connection failure, so the
  existing retry and backoff applies.

**Privacy.** Tokens live only in this Mac's Keychain (this-device-only, never
synced). No Sentwise server sees a Google token or any mail. The managed
inference proxy is not involved.

**Loopback listener fix.** The parked item-3 listener failed at start with
`NWError` POSIX 22 (EINVAL) because it pinned `requiredLocalEndpoint` to
`127.0.0.1` with port `.any`. It now uses `NWListener(using:on: .any)` and stays
on IPv4 loopback through `requiredInterfaceType = .loopback`. A real-socket unit
test covers it (`LoopbackRedirectListenerTests`).

---

## Switching the feature on per build

The repo ships `Sentwise/Config/GoogleOAuth.xcconfig` with **empty** values.
Any build made from the repo as-is (CI, forks, contributors, Prowl QA) has the
feature **off**: no Google button, and onboarding and Settings look exactly as
they did before.

To switch it on:

- **Local build:** copy `Sentwise/Config/GoogleOAuth.local.xcconfig.example` to
  `Sentwise/Config/GoogleOAuth.local.xcconfig` (git-ignored) and fill in the
  client ID and secret.
- **Release build (CI):** add repository secrets `SENTWISE_GOOGLE_CLIENT_ID` and
  `SENTWISE_GOOGLE_CLIENT_SECRET`. `release.yml` passes them to
  `Distribution/scripts/release.sh`, which forwards them to `xcodebuild archive`
  only when they are set.
- **Ad hoc:** `xcodebuild … SENTWISE_GOOGLE_CLIENT_ID=… SENTWISE_GOOGLE_CLIENT_SECRET=…`.
  Command-line settings override both xcconfig files.

The app treats an empty, unexpanded (`$(…)`), placeholder, or malformed client ID
(anything not ending in `.apps.googleusercontent.com`) as "not configured".

The secret of a Google "Desktop app" client is not confidential: Google's
installed-app guidance says so, and anything inside a shipped binary can be
extracted. PKCE protects the authorization code. The secret stays out of the repo
only so forks and CI builds do not pass themselves off as the Sentwise client.
**Never commit a real client ID or secret.**

---

## What the owner must do on Google's side

These steps are dashboard work in Google Cloud Console (Google Auth Platform).
Console labels change from time to time, so check them at setup time.

### 1. Project and API
1. Create (or pick) a Google Cloud project owned by the company account, e.g.
   `sentwise-prod`.
2. Enable the **Gmail API** (APIs & Services → Library). IMAP/SMTP XOAUTH2 does
   not call it, but Google reviews restricted Gmail scopes under it.

### 2. Branding and audience (OAuth consent screen)
1. **Branding:** app name `Sentwise`, user support email `support@sentwise.ai`,
   app logo, application home page `https://sentwise.ai`, privacy policy URL,
   terms of service URL, authorized domain `sentwise.ai`, developer contact email.
2. Verify ownership of `sentwise.ai` in Google Search Console with the same
   Google account. Brand verification requires it.
3. **Audience:** User type **External**. While it is in **Testing**, add test
   users (up to 100). In Testing mode, refresh tokens expire after **7 days**,
   so testers have to sign in again weekly. The app handles this with the
   "sign in with Google again" message.
4. **Data access (scopes):** add `https://mail.google.com/` (restricted),
   `openid`, and `.../auth/userinfo.email`.

### 3. OAuth client
1. Clients → **Create client** → Application type **Desktop app**, name e.g.
   `Sentwise macOS`.
2. **Redirect URI: nothing to register.** Desktop-app clients accept loopback
   redirects to `http://127.0.0.1:<any port>` automatically. Sentwise picks a
   random free port per sign-in and sends `redirect_uri=http://127.0.0.1:<port>`
   (no path). Do **not** create a "Web application" client. It would require
   fixed redirect URIs and the flow would fail.
3. Copy the client ID (`….apps.googleusercontent.com`) and client secret into the
   repository secrets / local xcconfig described above. Do not put them in the repo.

### 4. Restricted-scope verification (needed before public launch)
Unverified apps that request a restricted scope show the "Google hasn't verified
this app" interstitial and are capped at 100 users. Before switching the feature
on for everyone:
1. Audience → **Publish app** (move it to In production), then submit for
   verification from the Verification Center.
2. Provide a **scope justification** for `https://mail.google.com/`. IMAP/SMTP
   access requires this scope, and no narrower scope works with XOAUTH2. Explain
   that Sentwise reads the inbox and Sent mail to learn the user's writing voice
   and draft replies and follow-ups, and that it sends only messages the user
   approves.
3. Record a **demo video** (unlisted YouTube). It should show the full sign-in
   flow with the consent screen and the client ID visible in the browser address
   bar, then the app reading mail and sending an approved draft.
4. The **privacy policy** on sentwise.ai must describe Gmail data use and include
   the Google API Services User Data Policy **Limited Use** disclosure: data is
   used only to provide the user-facing features, never sold, never used for ads,
   and humans do not read it except as the policy allows. It should also state the
   local-first facts: mail and tokens stay on the user's Mac, and no Sentwise
   server stores mail.
5. Google's review commonly takes **2–6+ weeks**. This clock is outside our
   control, so submit as soon as the integration demos.

### 5. CASA security assessment (annual)
Restricted Gmail scopes require a **CASA** (Cloud Application Security
Assessment) through a Google-authorized lab, assigned during verification and
renewed every year.
- Expect **Tier 2** for this app shape: a scan-based assessment, roughly
  **$500–$1,000/yr** with labs such as TAC Security. Full lab audits (Tier 3) run
  $4.5k–$15k+. Confirm the tier and current pricing when Google assigns it.
- Local-first is a strong fit. No server touches mail, and tokens live in the
  Keychain (this-device-only), so the assessment is mostly documentation, not
  re-architecture. Have ready: the data-flow description (this doc), the
  Keychain storage details, and the fact that the managed proxy never receives
  mail credentials.
- Upload the lab's Letter of Validation to the Verification Center, and put the
  annual renewal on the calendar.

### 6. Google Workspace customers
Some Workspace admins restrict third-party apps. Until the app is verified, or
if the admin blocks unconfigured apps, users may see "access blocked". The admin
can allow the Sentwise client ID under Admin console → Security → API controls →
App access control. The app-password path stays available as the fallback.

---

## Testing

- **Unit (default suite):** `GmailAuthCoordinatorTests` (flow, phases, scopes,
  ID-token email, refresh, `invalid_grant`, revoke), `GmailAuthStoreTests`,
  `OAuthTokenServiceTests`, `LoopbackRedirectListenerTests` (real loopback socket),
  `GoogleSignInTests` (build switch, Google-vs-app-password selection,
  `GoogleOAuthMailProvider`, AppState connect/disconnect/switch/remove), and in
  the mail package `XOAuth2Tests` (SASL string incl. Google's example vector,
  IMAP `AUTHENTICATE XOAUTH2`, SMTP `AUTH XOAUTH2`, error-challenge handling).
- **Live (opt-in, never runs by default):** `GmailOAuthLiveTests` refreshes a
  real grant and authenticates Gmail IMAP with XOAUTH2 (read-only). Set
  `SENTWISE_LIVE_GOOGLE_OAUTH_EMAIL`, `SENTWISE_LIVE_GOOGLE_OAUTH_CLIENT_ID`,
  `SENTWISE_LIVE_GOOGLE_OAUTH_CLIENT_SECRET` (optional), and
  `SENTWISE_LIVE_GOOGLE_OAUTH_REFRESH_TOKEN` (with the `TEST_RUNNER_` prefix under
  `xcodebuild test`; see `docs/live-verification.md`). Run it only on the QA
  runner. To get a refresh token, sign in once with a configured dev build on the
  QA Mac and read the `refreshToken` field of the Keychain item
  `gmail.oauthToken.<email>` (service `com.tookes.Sentwise`).
- **Manual end to end** (QA Mac, not a developer workstation): with a configured
  build, Sign in with Google from onboarding, confirm the mailbox connects,
  drafts, and sends. Then disconnect and confirm the app is gone from
  https://myaccount.google.com/permissions.
