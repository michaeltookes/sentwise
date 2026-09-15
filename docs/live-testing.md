# Live-testing pipeline (Lucius)

The standing mechanism for live-verifying Sentwise: a GitHub Actions workflow
that runs the env-gated live test suite on the **Lucius Mac mini** self-hosted
runner, plus a thin `/live-verify` skill that dispatches it on demand. The
division of labor is deliberate:

- **The workflow (`.github/workflows/live-tests.yml`) is the executor and system
  of record.** It is the *only* place the `SENTWISE_LIVE_*` tests actually run.
- **The `/live-verify` skill is only a dispatcher** — `gh workflow run` + poll +
  report. It never runs a test on the invoking machine.

Live testing is delegated to Lucius so the owner's own Mac is never locked up by
a click-through, and so live regressions are caught automatically on merge.

> The per-test details (what each live test exercises, its credentials, and how
> to run one *locally* against your own account) live in
> [`docs/live-verification.md`](live-verification.md). This document is about the
> **pipeline**. The tests themselves are the payloads it runs.

## Why a dedicated pipeline (not per-PR CI)

The live tests hit real services — Clerk, the `sentwise-service` Worker, the
Paddle **sandbox**, and live IMAP mailboxes — and drafting spends real Anthropic
budget. Running them on every PR commit would be slow, flaky, and costly. So they
run only:

- **on `push` to `main`** — every merge is re-verified automatically; and
- **on `workflow_dispatch`** with a `ref` input — on demand for a branch, which
  is what `/live-verify` triggers.

Live execution is serialized by the single Lucius self-hosted runner. Do **not**
add a global Actions `concurrency` group for this workflow: GitHub keeps at most
one pending run per group and can cancel older pending dispatches, which would
violate the "verify every merge / watch the exact dispatch" guarantee.

## Scope guardrail (standing)

The live suite **signs in, drafts, checks the checkout overlay _loads_, and
fetches portal links**. It **NEVER**:

- completes a purchase or enters card data;
- touches any billing change control (upgrade/downgrade/cancel);
- sends mail to a third party (every live mail test is self-addressed and
  cleaned up).

This is the 2026-09-10 billing-guardrail decision applied to automated testing.
Never add a payload that would violate it.

## The env-injection recipe

App-hosted XCTest bundles do **not** inherit a plain shell `env`, so the
`SENTWISE_LIVE_*` gates must be written into the `.xctestrun` the runner
executes. The workflow follows the documented three-step recipe (see
`docs/managed-inference.md` → *Live verification*):

1. `xcodebuild build-for-testing` → produces `build/Build/Products/*.xctestrun`.
2. **`Distribution/scripts/inject-live-env.sh <xctestrun>`** writes each
   `SENTWISE_LIVE_*` secret that is set (and non-empty) into the xctestrun's
   `EnvironmentVariables`. Unset ones are skipped, so their gated tests skip
   cleanly. The script logs variable **names only** — never values — so secrets
   never reach the CI log. It handles xctestrun FormatVersion 1 and 2, and uses
   `plutil -extract … -o -` for its read-only probes so it never corrupts the
   file.
3. `xcodebuild test-without-building -xctestrun <xctestrun>` runs the suite,
   scoped with `-only-testing` to just the live classes.

`inject-live-env.sh` is a standalone, shellcheck-clean script precisely so it can
be tested outside the workflow.

## Secrets to provision (owner checklist)

The workflow references these as **repository secrets**. Provision them in
GitHub → Settings → Secrets and variables → Actions. Any left unprovisioned make
their gated test **skip** (not fail) — the run still succeeds, but that payload
is not exercised, so provision the ones you want covered.

| Secret | Gates | Notes |
| --- | --- | --- |
| `SENTWISE_LIVE_PADDLE_CHECKOUT` | `PaddleCheckoutLiveTests` | Any truthy value (`1`). Renders the Paddle **sandbox** checkout overlay; no purchase. Requires `sentwise.ai` to be an approved domain in the Paddle sandbox account (it is the harness base origin). |
| `SENTWISE_LIVE_CLERK_TEST` | `ClerkLiveSignInTests` | Any truthy value (`1`). Uses Clerk's `+clerk_test` address + universal code `424242` — no real inbox, no secret key. |
| `SENTWISE_LIVE_GMAIL_EMAIL` | `GmailLiveSendTests`, `ReplyWorthinessLiveTests` | The Gmail address. |
| `SENTWISE_LIVE_GMAIL_APP_PASSWORD` | same | 16-char Google app password (2FA required). |
| `SENTWISE_LIVE_ATTNET_EMAIL` | `AttNetLiveDraftTests` | The att.net address (item 44 save-as-draft verify). |
| `SENTWISE_LIVE_ATTNET_APP_PASSWORD` | same | AT&T Secure Mail Key. |
| `SENTWISE_LIVE_MANAGED_INFERENCE` | `ManagedInferenceLiveTests` | Any truthy value (`1`). Explicitly opts the Worker account-shape tests into live Worker calls. The test mints a fresh Clerk session JWT during the run using `SENTWISE_LIVE_CLERK_TEST`; no JWT is stored as a repo secret. |
| `SENTWISE_LIVE_MANAGED_DRAFT` | `ManagedInferenceLiveTests.testLiveDraftReturnsText` | Optional. Any truthy value (`1`) enables the live `/v1/draft` spend check. Provision only with `SENTWISE_LIVE_MANAGED_DRAFT_EMAIL` below. |
| `SENTWISE_LIVE_MANAGED_DRAFT_EMAIL` | `ManagedInferenceLiveTests.testLiveDraftReturnsText` | Optional with `SENTWISE_LIVE_MANAGED_DRAFT`. A Clerk `+clerk_test` email whose Worker account has a durable entitlement or trial bypass; otherwise recurring push-to-main runs will eventually fail when the normal trial expires. |
| `SENTWISE_INFERENCE_URL` | `ManagedInferenceLiveTests` | The deployed Worker base URL (`https://sentwise-inference.sentwise-service.workers.dev`). |

Optional IMAP host/port overrides (`SENTWISE_LIVE_GMAIL_HOST` / `_PORT`,
`SENTWISE_LIVE_ATTNET_HOST` / `_PORT`) default to the provider's standard
endpoint; add them to both the workflow `env:` block and `inject-live-env.sh`'s
`LIVE_VARS` list only if a non-default endpoint is ever needed.

> **Never** print, echo, or commit a secret value. The injection script and the
> workflow are written to log names only.

## The tests the pipeline runs (`-only-testing`)

```
SentwiseTests/PaddleCheckoutLiveTests
SentwiseTests/ClerkLiveSignInTests
SentwiseTests/ManagedInferenceLiveTests
SentwiseTests/GmailLiveSendTests
SentwiseTests/ReplyWorthinessLiveTests
SentwiseTests/AttNetLiveDraftTests
```

`PaddleCheckoutLiveTests` is the first checkout payload (item 97 / closes item
95's pending live check): it loads the real `PaddleCheckoutHTML` harness in a
`WKWebView` under the real `CheckoutNavigationPolicy` navigation rule, opens the
Paddle **sandbox** overlay by `items` (client-side token + a sandbox price id),
and asserts the overlay reaches Paddle's real `checkout.loaded` event while the
navigation policy blocked none of the Paddle navigations the overlay needs. This
catches the "navigation policy too tight" regression class that offline unit
tests cannot. It needs a window server, which is why it runs only on Lucius's GUI
session. See the file's header for why it opens by `items` rather than chaining a
live Clerk sign-in + server-minted transaction (the overlay and its sub-frames
render identically either way, with far fewer live dependencies).

`ManagedInferenceLiveTests` mints a fresh Clerk session token during each run.
The `/v1/me` account-shape checks run under `SENTWISE_LIVE_MANAGED_INFERENCE`;
the `/v1/draft` spend check has the extra `SENTWISE_LIVE_MANAGED_DRAFT` gate and
uses `SENTWISE_LIVE_MANAGED_DRAFT_EMAIL`, so recurring runs only enable drafting
with a Clerk test account that cannot age out of its trial.

## Dispatching a run

### From an agent session

Use the **`/live-verify`** skill (`.claude/skills/live-verify/SKILL.md`). It
resolves the ref (current branch by default), runs
`gh workflow run live-tests.yml` with a branch/tag workflow ref and a separate
checkout `ref` input, watches the correlated run to completion, and reports
pass/fail with `gh run view --log-failed` excerpts. It never runs a test locally.
It is wired into the `/kickoff` lifecycle as the final live-verify step after
`/validate-feature` passes and the branch is pushed; merges to `main` are
covered automatically by the push trigger.

### Manually

```bash
REQUESTED_REF=<branch-or-tag-or-sha>
WORKFLOW_REF=<branch-or-tag-containing-live-tests-yml>
CHECKOUT_REF=<exact-pushed-sha-or-requested-tag-or-sha>
CORRELATION_ID="manual-live-$(date -u +%Y%m%dT%H%M%SZ)"
CREATED_AFTER="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

gh workflow run live-tests.yml \
  --ref "$WORKFLOW_REF" \
  -f ref="$CHECKOUT_REF" \
  -f correlation_id="$CORRELATION_ID"

RUN_ID=""
for _ in {1..24}; do
  RUN_ID=$(gh run list \
    --workflow=live-tests.yml \
    --event workflow_dispatch \
    --created ">=$CREATED_AFTER" \
    --json databaseId,displayTitle \
    --jq "map(select((.displayTitle // \"\") | contains(\"$CORRELATION_ID\"))) | .[0].databaseId // \"\"")
  [ -n "$RUN_ID" ] && break
  sleep 5
done
[ -n "$RUN_ID" ] || { echo "run not found: $CORRELATION_ID" >&2; exit 1; }
gh run watch "$RUN_ID" --exit-status
```

Branches and tags must be pushed to `origin` first; SHA inputs must be reachable
from the repository so `actions/checkout` can fetch them. For branch refs,
compare the local branch object id with the remote branch object id first, then
pass that exact pushed SHA as `CHECKOUT_REF`. For an explicit SHA, dispatch the
workflow definition from a branch or tag and pass the SHA only as `CHECKOUT_REF`.

## Runner hygiene (Lucius)

Same constraint as `prowl-qa.yml` (see `.prowl/README.md`):

- The runner is the **Lucius Mac mini**, registered with labels
  `self-hosted, macOS` and Xcode installed.
- It **must be started from Lucius's on-console GUI (Aqua) session** — run
  `svc.sh` from that session, **never over SSH and never with sudo**. WebKit's
  window server (the checkout-overlay test) and any GUI-dependent flow fail if
  the runner is detached from the on-console session. A detached runner shows up
  as `{"trusted":false}` Accessibility failures / missing window server.
- Only one live run executes at a time because the Lucius runner is the single
  eligible self-hosted macOS runner. Preserve every queued run; do not add a
  global workflow concurrency group.
- Known infra flake: `xcodebuild test` occasionally fails with undefined NIO
  symbols or a hung test runner — an environment flake, not a code bug. Recover
  by killing any stray `Sentwise` process, `rm -rf ./build`, `pkill xctest` and
  `pkill testmanagerd`, then re-run. A reboot is never needed.

## Adding a new live payload

1. **Write the test** in `Sentwise/SentwiseTests/…LiveTests.swift`, gated on a
   `SENTWISE_LIVE_*` env var that throws `XCTSkip` when unset (mirror
   `ClerkLiveSignInTests` / `PaddleCheckoutLiveTests`). Keep it inside the scope
   guardrail. Confirm it compiles and **skips** under a normal
   `xcodebuild test` (gate absent) — never run it live locally.
2. **Add its gate var** to `LIVE_VARS` in
   `Distribution/scripts/inject-live-env.sh` (and any optional host/port vars).
3. **Reference the secret** in the workflow's *Inject live env* `env:` block, and
   **add the class** to the `-only-testing` list in the *Run live tests* step.
4. **Document it**: add the secret to the checklist above and the test to
   `docs/live-verification.md`.
5. **Provision the secret** in GitHub (owner), then dispatch with `/live-verify`.
