# Live verification tests

Some integration tests exercise **real** services — a live IMAP/SMTP mailbox, the
real Clerk instance, or the Paddle sandbox — instead of a test double. They are
the headless-XCTest equivalent of a manual click-through (the standing QA
preference) and close the remaining "verify against a real account" criteria of
backlog items 9, 44, 66, and 95.

They are **env-gated**: with no credentials/flags in the environment they throw
`XCTSkip` and pass as skipped, so CI and any machine without a live account stay
green. Nothing is ever delivered to a third party — every mail test is
**self-addressed** (the recipient is the account's own address) and is moved to
Trash at the end of the test (recoverable, non-destructive), even when a
verification assertion fails; the checkout test never enters card data or
completes a purchase.

> These tests are the **payloads** of the live-testing pipeline: they run on the
> **Lucius** self-hosted runner via `.github/workflows/live-tests.yml`, dispatched
> by the `/live-verify` skill or automatically on merge to `main`. This document
> catalogs the tests and their credentials; the pipeline itself (workflow,
> triggers, repo-secret provisioning, runner hygiene) is documented in
> [`docs/live-testing.md`](live-testing.md). **Live tests are never run on the
> owner's Mac** — they run on Lucius.

## Tests

| Test | Item | What it exercises |
| --- | --- | --- |
| `GmailLiveSendTests` | 9 | Dispatches a reply through the app's real auto-send path (`AppState.performSend` → SMTP submission over implicit TLS on the derived `smtp.` host, port 465), then fetches the delivered copy back from the inbox and asserts recipient addressing, the marker subject, and the `In-Reply-To` threading header. Also confirms Gmail auto-filed a copy in Sent Mail, then trashes every copy. |
| `AttNetLiveDraftTests` | 44 | Saves a reply to the real Drafts mailbox through the app's save path (IMAP `APPEND` with `\Draft`), fetches it back to assert addressing + threading, then trashes it. |
| `ReplyWorthinessLiveTests` | 66 | **Read-only.** Runs a fresh reply-worthiness pass (the same `AppState.replyWorthinessSkipReason` the watcher uses, including the live `HEADER.FIELDS` fetch) over recent inbox mail and asserts that known machine-sending senders (GitHub, Stripe/Anthropic receipts, AWS cost alerts, recruiting blasts) produce a skip — zero drafts — while personal mail stays worthy. Never drafts, sends, or mutates the mailbox; reuses the Gmail credentials below. |
| `ClerkLiveSignInTests` | 59 | Email-code sign-in against the real Clerk dev instance via the Frontend API, exercising the real `ClerkClient`. Uses Clerk's `+clerk_test` address + universal code `424242` — no real inbox, no secret key. Gated on `SENTWISE_LIVE_CLERK_TEST`. See `docs/managed-inference.md`. |
| `ManagedInferenceLiveTests` | 56b / 73 / 97 | Calls the deployed `sentwise-service` Worker (`/v1/me`, optional quota/subscription blocks, and `/v1/draft`) with a fresh Clerk session JWT minted during the run through Clerk's test email-code flow. Gated on `SENTWISE_LIVE_MANAGED_INFERENCE`, `SENTWISE_LIVE_CLERK_TEST`, and `SENTWISE_INFERENCE_URL`. |
| `PaddleCheckoutLiveTests` | 95 / 97 | **No purchase.** Loads the real `PaddleCheckoutHTML` harness in a `WKWebView` under the real `CheckoutNavigationPolicy` navigation rule and drives the harness's own `window.sentwiseOpenCheckout` to open the **Paddle sandbox** overlay by `items` (client-side token + a sandbox price id). Asserts the overlay reaches Paddle's real `checkout.loaded` event and that the navigation policy blocked none of the Paddle navigations the overlay needs — catching the "navigation policy too tight" regression class. Needs a window server (Lucius GUI session). Gated on `SENTWISE_LIVE_PADDLE_CHECKOUT`. |

## Credentials

Each test reads its credentials from environment variables. Required vars are
gated; optional host/port vars default to the provider's standard IMAP endpoint.

**Gmail** (`GmailLiveSendTests`, `ReplyWorthinessLiveTests`) — requires a Google **app password** (2FA on):

- `SENTWISE_LIVE_GMAIL_EMAIL` — the Gmail address (required)
- `SENTWISE_LIVE_GMAIL_APP_PASSWORD` — its 16-character app password (required)
- `SENTWISE_LIVE_GMAIL_HOST` — IMAP host (optional; default `imap.gmail.com`)
- `SENTWISE_LIVE_GMAIL_PORT` — IMAP port (optional; default `993`)

**att.net** (`AttNetLiveDraftTests`) — requires an AT&T **Secure Mail Key**:

- `SENTWISE_LIVE_ATTNET_EMAIL` — the att.net address (required)
- `SENTWISE_LIVE_ATTNET_APP_PASSWORD` — its Secure Mail Key (required)
- `SENTWISE_LIVE_ATTNET_HOST` — IMAP host (optional; default `imap.mail.att.net`)
- `SENTWISE_LIVE_ATTNET_PORT` — IMAP port (optional; default `993`)

**Clerk** (`ClerkLiveSignInTests`) — no real credentials needed (Clerk test mode):

- `SENTWISE_LIVE_CLERK_TEST` — any truthy value (`1`) to run it (required)

**Managed inference Worker** (`ManagedInferenceLiveTests`) — uses Clerk test
mode to mint a fresh session token at runtime:

- `SENTWISE_LIVE_MANAGED_INFERENCE` — any truthy value (`1`) to run it (required)
- `SENTWISE_LIVE_CLERK_TEST` — any truthy value (`1`) to enable the Clerk test
  email-code flow (required)
- `SENTWISE_INFERENCE_URL` — deployed Worker base URL (required)

**Paddle** (`PaddleCheckoutLiveTests`) — sandbox only, no purchase:

- `SENTWISE_LIVE_PADDLE_CHECKOUT` — any truthy value (`1`) to run it (required).
  The sandbox client-side token and price ids are embedded in `PaddleConfig`;
  `sentwise.ai` must be an approved domain in the Paddle sandbox account (it is
  the harness base origin).

The SMTP submission host and port are **derived** from the IMAP host: a leading
`imap.` is swapped for `smtp.` (Gmail: `smtp.gmail.com`) and the port defaults to
`465` (implicit TLS). There is no separate SMTP credential.

### `.env`

Put the credentials in a repo-root `.env` file (it is **gitignored** — never
commit it):

```sh
# .env — placeholders; fill in real values
SENTWISE_LIVE_GMAIL_EMAIL=you@gmail.com
SENTWISE_LIVE_GMAIL_APP_PASSWORD=xxxxxxxxxxxxxxxx
# att.net (optional — only needed for AttNetLiveDraftTests)
SENTWISE_LIVE_ATTNET_EMAIL=you@att.net
SENTWISE_LIVE_ATTNET_APP_PASSWORD=xxxxxxxxxxxxxxxx
```

## How env vars reach the test process

Under `xcodebuild test`, variables from the invoking shell are **not** inherited
by the test process. They must be forwarded with the **`TEST_RUNNER_` prefix**:
Xcode's test runner strips that prefix and passes the variable through to the
test process's environment (where the test reads it under its bare name).

This is verified: a plain `FOO=bar xcodebuild test …` leaves `FOO` invisible to
the test (`ProcessInfo` returns `nil`), while `TEST_RUNNER_FOO=bar xcodebuild
test …` makes the test see `FOO=bar`.

## Working invocation

Source `.env`, then forward each variable with the `TEST_RUNNER_` prefix. This
runs only the Gmail live send test:

```sh
set -a; source .env; set +a

xcodebuild test \
  -project Sentwise/Sentwise.xcodeproj \
  -scheme Sentwise \
  -destination 'platform=macOS' \
  -only-testing:SentwiseTests/GmailLiveSendTests \
  TEST_RUNNER_SENTWISE_LIVE_GMAIL_EMAIL="$SENTWISE_LIVE_GMAIL_EMAIL" \
  TEST_RUNNER_SENTWISE_LIVE_GMAIL_APP_PASSWORD="$SENTWISE_LIVE_GMAIL_APP_PASSWORD"
```

For the att.net draft test, swap the `-only-testing` target and forward the
att.net vars instead:

```sh
set -a; source .env; set +a

xcodebuild test \
  -project Sentwise/Sentwise.xcodeproj \
  -scheme Sentwise \
  -destination 'platform=macOS' \
  -only-testing:SentwiseTests/AttNetLiveDraftTests \
  TEST_RUNNER_SENTWISE_LIVE_ATTNET_EMAIL="$SENTWISE_LIVE_ATTNET_EMAIL" \
  TEST_RUNNER_SENTWISE_LIVE_ATTNET_APP_PASSWORD="$SENTWISE_LIVE_ATTNET_APP_PASSWORD"
```

`ReplyWorthinessLiveTests` reads the **same Gmail vars** — run it by swapping the
`-only-testing` target to `SentwiseTests/ReplyWorthinessLiveTests` in the Gmail
invocation above (it forwards `TEST_RUNNER_SENTWISE_LIVE_GMAIL_EMAIL` /
`_APP_PASSWORD`). It is read-only, so nothing is sent or trashed.

Optional host/port overrides forward the same way (e.g.
`TEST_RUNNER_SENTWISE_LIVE_GMAIL_HOST="$SENTWISE_LIVE_GMAIL_HOST"`).

Without the `TEST_RUNNER_` arguments the live tests skip and the rest of the
suite runs normally.

> **Never** print, echo, log, or commit credential values. `.env` is gitignored;
> keep it that way. The docs above use placeholders only.

## Known infra flakes

`xcodebuild test` occasionally fails with undefined NIO symbols or a hung test
runner. These are environment flakes, not code bugs. To recover: kill any stray
`Sentwise` process, `rm -rf ./build`, `pkill` `xctest` and `testmanagerd`,
then re-run. A reboot is never needed.
