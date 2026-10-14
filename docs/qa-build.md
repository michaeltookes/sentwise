# QA build ("Sentwise QA")

Backlog item 123. The QA build is the production code built with the **QA** build configuration. It
talks to the **sandbox deployment** of `sentwise-service` (`sentwise-inference-sandbox`, configured
for the Paddle sandbox and a Clerk development instance), so QA can buy a plan with a Paddle test
card. It installs **beside** the production app on the QA Mini and shares nothing with it.

Production builds (the Debug and Release configurations) never read the QA settings. Two guards
make sure of it:

- Debug and Release define every `SENTWISE_*` build setting as empty in the project, so a shell
  variable exported for a QA build (for example before running `qa-build.sh`) cannot expand into a
  production Info.plist. Only the QA configuration takes them, from `QA.xcconfig`, or from explicit
  `xcodebuild` command-line settings.
- `BuildConfiguration` honors the `Sentwise…` keys only in a bundle whose identifier is
  `com.tookes.Sentwise.<suffix>`. With the production bundle id, every value resolves to the
  compiled-in production default whatever the plist holds, so nothing moves for existing installs.

## What differs from production

| | Production (`Sentwise`) | QA (`Sentwise QA`) |
| --- | --- | --- |
| Bundle id | `com.tookes.Sentwise` | `com.tookes.Sentwise.qa` |
| Name (Finder, status item, menu, Quit item) | Sentwise | Sentwise QA |
| App bundle | `/Applications/Sentwise.app` | `/Applications/Sentwise QA.app` |
| Service | `https://sentwise-inference.sentwise-service.workers.dev` | `https://sentwise-inference-sandbox.sentwise-service.workers.dev` |
| Clerk Frontend API (sign-in and session tokens) | `https://clerk.sentwise.ai` | the Clerk development instance |
| Paddle | live token and prices, `Paddle.Environment` default | sandbox token and prices, `Paddle.Environment.set("sandbox")` |
| Keychain service | `com.tookes.Sentwise` | `com.tookes.Sentwise.qa` |
| Data folder | `~/Library/Application Support/Sentwise` | `~/Library/Application Support/Sentwise QA` |
| URL scheme (sign-in callbacks) | `sentwise://` | `sentwise-qa://` |
| Sparkle auto-update | on | off (the appcast serves the production app) |
| Unified-log subsystem (diagnostics reports) | `com.tookes.Sentwise` | `com.tookes.Sentwise.qa` |
| "Turn on notifications" deep link | System Settings entry for `com.tookes.Sentwise` | entry for `com.tookes.Sentwise.qa` |
| UserDefaults, login item, notifications | per bundle id | per bundle id (separate automatically) |

The separate Keychain service is what keeps the QA build away from the production install's items.
Item 115 (`docs/live-testing.md`) is the history: a differently signed process that rewrites an item
under `com.tookes.Sentwise` resets its ACL and locks the Developer ID app behind a login-keychain
prompt. The QA build never reads or writes that service.

**Fail closed, never production.** The bundle id alone decides what a build is: a
`com.tookes.Sentwise.<suffix>` bundle is always a QA build, even if every `Sentwise…` key is missing.
Its Keychain suffix, data folder, name, and URL scheme then come from the suffix (`.qa`,
`Sentwise QA`, `sentwise-qa`), Sparkle stays off, and the services below are unavailable. In a QA build, a missing, malformed, or production Clerk URL makes
sign-in unavailable (the Clerk client refuses the reserved `clerk-unavailable.invalid` host before
any request). A missing or malformed service URL does the same for drafting. An incomplete or
inconsistent Paddle config makes checkout unavailable: Subscribe, Upgrade, and plan changes are
disabled with "Checkout isn't available in this build.". A QA build never uses production prices,
the production Clerk instance, the production Keychain service, or the production data folder.
`SentwiseTests/BuildConfigurationTests.swift` covers each case.

## Configuration files

- `Sentwise/Config/QA.xcconfig` (committed): the identity values, the sandbox service URL, and
  `SENTWISE_PADDLE_ENVIRONMENT = sandbox`. The values not known yet are empty.
- `Sentwise/Config/QA.local.xcconfig` (git-ignored, copy from `QA.local.xcconfig.example`): your
  local Clerk URL and Paddle sandbox values. It is `#include?`d at the end of `QA.xcconfig`.
- `Sentwise/Info.plist` expands the settings into `SentwiseServiceBaseURL`,
  `SentwiseClerkFrontendAPIURL`, `SentwisePaddleEnvironment`, `SentwisePaddleClientToken`,
  `SentwisePaddle{Starter,Pro,Unlimited}PriceID`, `SentwiseKeychainServiceSuffix`, and
  `SentwiseAppSupportDirectoryName`, plus the suffixed `CFBundleURLSchemes` entry.
- The QA build configuration in `Sentwise.xcodeproj` is a copy of Release whose app target is based on
  `QA.xcconfig`; it also sets the bundle id suffix and display name from it.

Write URLs in an xcconfig as `https:$(SLASH)$(SLASH)host`, because `//` starts a comment there.

### Values to fill

| Setting | Where | Value |
| --- | --- | --- |
| `SENTWISE_CLERK_FRONTEND_API_URL` | `QA.local.xcconfig` locally; repository variable `SENTWISE_QA_CLERK_FRONTEND_API_URL` in CI | Clerk development instance Frontend API URL, `https://<name>.clerk.accounts.dev` |
| `SENTWISE_PADDLE_CLIENT_TOKEN` | same; `SENTWISE_QA_PADDLE_CLIENT_TOKEN` | Paddle sandbox client-side token (`test_…`) |
| `SENTWISE_PADDLE_STARTER_PRICE_ID` | same; `SENTWISE_QA_PADDLE_STARTER_PRICE_ID` | Sandbox Starter price (`pri_…`) |
| `SENTWISE_PADDLE_PRO_PRICE_ID` | same; `SENTWISE_QA_PADDLE_PRO_PRICE_ID` | Sandbox Pro price (`pri_…`) |
| `SENTWISE_PADDLE_UNLIMITED_PRICE_ID` | same; `SENTWISE_QA_PADDLE_UNLIMITED_PRICE_ID` | Sandbox Unlimited price (`pri_…`) |

All five are public values (the app embeds them). The price ids must be the same ones the sandbox
Worker has in `env.sandbox.vars`. The app uses no Clerk publishable key; the Worker's
`CLERK_PUBLISHABLE_KEY` (`pk_test_…`) and secret key are set on the service side
(`sentwise-service/docs/sandbox-deployment.md`).

### Vendor setup this build depends on (vendor-ops)

- **Clerk development instance:** email-code sign-in enabled; redirect allowlist entry
  `https://sentwise-inference-sandbox.sentwise-service.workers.dev/auth/callback`. That page forwards to
  `sentwise-qa://oauth-callback` because the sandbox Worker sets `APP_CALLBACK_SCHEME=sentwise-qa`,
  the scheme only this build registers. Enable the Google social connection there too if Google
  sign-in is tested on the QA build.
- **Paddle sandbox:** approved domain `sentwise.ai`, client-side token, the three-tier catalog, and
  the webhook destination on the sandbox hostname (`docs/billing-qa.md`).

## Building it

### Locally

```bash
cp Sentwise/Config/QA.local.xcconfig.example Sentwise/Config/QA.local.xcconfig   # then fill it in
Distribution/scripts/qa-build.sh --unsigned --skip-dmg   # ad-hoc signed app in dist-qa/stage/
Distribution/scripts/qa-build.sh                          # Developer ID signed DMG in dist-qa/
```

Or in Xcode: pick the QA configuration for Run/Archive in the scheme editor. The script archives the
QA configuration, exports it, then **verifies the built Info.plist is a QA build** (bundle id, name,
URL scheme, Keychain suffix, data folder, sandbox service) before staging `Sentwise QA.app`, and
warns about any sign-in or checkout value that is unset or would leave checkout unavailable: a
placeholder from `QA.local.xcconfig.example`, a token that is not `test_…`, a price id that is not a
`pri_…` id or is a production price, or the production Clerk host (the same rules as
`BuildConfiguration`; `--require-checkout` turns that into a failure). `--notarize`
notarizes and staples the app and the DMG with the same credentials as `release.sh`. Output goes to
the git-ignored `dist-qa/`, never `dist/`, so the release pipeline can never pick it up.

Do not run the full `xcodebuild test` suite on a workstation; tests run in CI.

### In CI

**Actions → QA build → Run workflow** (`qa-build.yml`, dispatch only):

- `ref`: the release tag under test (the sandbox Worker must run the same tag; see the lockstep rule
  in `sentwise-service/docs/sandbox-deployment.md`).
- `signing`: `developer-id` (signed and notarized, the default), `developer-id-unnotarized`, or
  `unsigned` (ad-hoc, no credentials).
- `require_checkout`: fail unless the Clerk URL and all Paddle values are real sandbox values (default on).

It reuses the release signing and notarization secrets and the five `SENTWISE_QA_*` repository
variables above, and uploads `Sentwise-QA-<version>-<sha>.dmg` (plus its `.sha256`) as the
`sentwise-qa-…` workflow artifact. It never tags, creates a release, writes an appcast, or bumps the
Homebrew cask.

## Installing it on the QA Mini (Lucius)

1. Download the DMG artifact from the workflow run and check it against its `.sha256`.
2. Quit **Sentwise** with **Quit Sentwise** if it is running. Only one of the two apps runs at a time.
3. Open the DMG and drag **Sentwise QA** into `/Applications`. Never replace or rename
   `/Applications/Sentwise.app`.
4. Launch **Sentwise QA** from `/Applications`. Its status item, menu header, and Quit item read
   "Sentwise QA". It has its own data folder and Keychain items, so it starts signed out with default
   settings, and macOS may ask once for notification permission.
5. Sign in with the sandbox purchaser (F3 in `docs/qa/test-cases.md`). Its code arrives by email as
   usual; the account is created in the Clerk development instance, never in production.
6. Before going back to production, quit **Sentwise QA** with **Quit Sentwise QA**.

To remove it: quit it, delete `/Applications/Sentwise QA.app` and
`~/Library/Application Support/Sentwise QA`, and delete the `com.tookes.Sentwise.qa` items in Keychain
Access. Nothing of the production install is touched.

## TC-M3-05 on this design

The case text lives in `docs/qa/test-cases.md` (plan branch); this is the procedure it relies on.

1. **Before the run:** production runs release tag `vX.Y.Z`. Dispatch **Deploy sandbox** in
   `sentwise-service` with `ref: vX.Y.Z`, then **QA build** here with `ref: vX.Y.Z`. Record both run
   links and the tag in the report.
2. **Production check (read-only), in Sentwise:** a trial-ended production account opens Subscribe →
   Starter and the checkout shows the live $9.00 price with no sandbox marking. No card is entered on
   production. The production build has no sandbox configuration, so this is a single confirmation,
   not a routing test.
3. Quit **Sentwise**; launch **Sentwise QA**; sign in as F3 (Clerk development instance).
4. Using the sandbox admin token, backdate F3's trial on `{sandbox}` so it reads "Trial ended", and
   record the sandbox funnel baseline.
5. In **Sentwise QA**: Settings… → Subscription → Subscribe → Starter. The Paddle overlay shows the
   sandbox banner and the sandbox Starter price.
6. Pay with the sandbox success card from `docs/billing-qa.md`. Expect "You're on Starter — you're all
   set." and, after reopening Subscription, Current plan Starter renewing about one month out.
7. Confirm on `{sandbox}` that the funnel counted the activation, and that F3 does not exist on the
   production Worker or in production Clerk.
8. Afterwards: keep F3 for TC-M3-06 to TC-M3-10, then cancel its sandbox subscription and delete F3
   from the Clerk development instance. No refund is needed.

If the sandbox deployment is unavailable, use the production fallback sequence in
`docs/billing-qa.md`.
