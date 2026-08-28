# Prowl hunts for Sentwise (experimental macOS target)

End-to-end QA hunts that drive the real Sentwise menu bar app through macOS
Accessibility (Prowl's experimental `macos` target, unreleased — requires the
locally-linked CLI, not the npm `prowl-tools` package).

## One-time setup

1. **CLI**: in the prowl repo, `npm run build && npm link` — puts `prowl` on
   your PATH pointing at the local build.
2. **Helper**: in the prowl repo, `cd macdriver && swift build -c release`.
   The linked CLI finds the binary automatically (or set `PROWL_MACDRIVER_BIN`).
3. **Permissions** (System Settings → Privacy & Security), granted to the
   terminal app you run `prowl` from:
   - **Accessibility** — required for everything.
   - **Screen Recording** — only needed for screenshot steps / failure
     screenshots.
4. **Build the app under test** from this checkout. The Prowl config points at
   this deterministic build product so hunts do not exercise an older installed
   Sentwise build:

   ```bash
   xcodebuild build \
     -project Sentwise/Sentwise.xcodeproj \
     -scheme Sentwise \
     -configuration Debug \
     -derivedDataPath .prowl/DerivedData \
     CODE_SIGNING_ALLOWED=NO
   ```

## Running

From the repo root:

```bash
prowl list
prowl run menu-smoke            # status-item menu opens; all safe actions exist (incl. Report a Problem, item 36)
prowl run diagnostics-settings  # item 36: Diagnostics section renders on the Settings General tab
prowl run follow-up-composer    # flagship: New Follow-up window opens
prowl run review-drafts         # approval surface: Review Drafts window opens
prowl run browse-mailbox        # Browse Mailbox window opens
prowl run setup-assistant       # onboarding window opens (item 64 surface)
prowl run settings-window       # Settings window opens (item 65 surface)
prowl run settings-window-tabs  # switching Settings tabs keeps the window put (item 65 regression)
prowl run activity-history      # Activity History window opens
prowl run ai-provider-controls  # item-59 sign-in/provider controls all render
prowl run managed-signin-email  # email-code managed sign-in via the offline fake (item 70)
prowl run managed-signin-google # Google managed sign-in via the offline fake (item 70)
prowl run openrouter-connect    # OpenRouter provisioning via the offline fake (item 70)
```

Each run launches the Sentwise app at
`.prowl/DerivedData/Build/Products/Debug/Sentwise.app`, drives it, and quits it
afterward. That bundle path automatically enables Sentwise's Prowl hunt mode
before app startup automation runs. Artifacts land in `.prowl/runs/`
(gitignored).

## Hunt mode: isolation + seeded fixture

Hunt mode (see `Sentwise/Sentwise/App/ProwlHuntRuntime.swift`) isolates runs
from the user's live Sentwise profile: settings, processed-message state,
pending drafts, activity history, voice profile, and secrets use in-memory
stores instead of Application Support and Keychain. Startup side effects are
disabled before UI is presented: Sparkle startup, notification authorization,
reachability monitoring, inbox watcher auto-resume, transcript-folder watcher
auto-resume, and first-run onboarding auto-open.

The in-memory stores are **seeded with a fake connected account** so the
account-gated menu surfaces exist and hunts can open every product window:

- Account `hunt.fixture@sentwise.invalid` on host `imap.sentwise.invalid` —
  the `.invalid` TLD (RFC 2606) never resolves, so nothing in the fixture can
  reach a real mail server. This unlocks **New Follow-up from Transcript** and
  **Browse Mailbox** (whose connection attempt fails fast and harmlessly).
- One pending fixture draft, which unlocks **Review Drafts (1)**.
- Onboarding marked complete, so the menu is in its normal steady state.
- **No LLM key and no verified model**, so watching stays unavailable and no
  provider can be called.

### Sign-in / provisioning are a deterministic offline fake in hunt mode (item 70)

The item-59 sign-in surfaces are **functional but fully offline** in hunt mode, so
hunts can drive them end-to-end without ever reaching the network. This is the
same intent as the `StubManagedInferenceClient` that answers drafts offline:

- **Managed email-code sign-in** — `startManagedSignIn` advances to the code stage
  and `verifyManagedCode` completes to the signed-in fixture account, both without
  any Clerk call (`AppState+ManagedAccount.swift`, gated on `isHuntMode`).
- **Managed Google sign-in** — `startManagedGoogleSignIn` shows the
  "finish in your browser" panel WITHOUT opening a real browser (the `openURL`
  hand-off is skipped in hunt mode), and a hunt-only **"Simulate browser sign-in"**
  control (`managedSimulateGoogleCallback`, compiled into the UI only in hunt mode)
  completes it via `completeManagedGoogleSignInForHunt`.
- **OpenRouter provisioning** — "Connect OpenRouter" completes to a fake
  OpenAI-compatible provider via `completeOpenRouterProvisioningForHunt` — no
  browser, no PKCE exchange, no real key.

Everything stays in memory against `.invalid`/fake fixtures; the production sign-in
paths are unchanged (every fake is strictly guarded on
`ProwlHuntRuntime.current.isEnabled`, injectable for unit tests — see
`AppState+ProwlHuntAuth.swift` and `AppStateProwlHuntAuthTests`). The signed-in
fixture account is `hunt.google@sentwise.invalid` (Google) or whatever email the
hunt types (email code).

The `.prowl/DerivedData` app path is part of that safety boundary. If you point
`target.app` somewhere else, do not present the hunts as live-account-safe
unless that build is launched with `SENTWISE_PROWL_HUNT_MODE=1` or
`--sentwise-prowl-hunt-mode` and the isolation still applies.

## Safety rules for authoring hunts

Hunts are **open-and-assert only for everything that mutates real state**: open
the menu, open windows, assert presence. Do not author steps that activate
controls that could send mail, mutate a draft, call a real LLM, search a mailbox,
or change system settings — no Generate, Send, Approve, Deny, Save, Delete,
Discard, Disconnect, Search, Test Connection, Start/Pause Watching, Launch at
Login, Check for Updates, or Quit. The `forbiddenSelectors` guardrails in
`config.yml` enforce this by substring — keep them in sync with any new
interactive surfaces.

### Exception: item-59 sign-in / provider controls (relaxed 2026-08-21, item 70)

Because managed sign-in (email + Google) and OpenRouter provisioning run through a
**deterministic, fully-offline fake in hunt mode** (see the fixture section above),
activating those specific controls cannot reach a real service or send anything.
The `forbiddenSelectors` were therefore relaxed so the sign-in/provider hunts can
click them, while every dangerous action stays forbidden. The relaxations (each
documented inline in `config.yml`):

- Removed the explicit `managed*` / `openRouter*` / `useThis*` id forbids and the
  sign-in *label* forbids ("Sign in", "Verify", "Send sign-in code", "Use Sentwise
  AI", "Continue with Google", "Connect OpenRouter", "Use this provider").
- Removed the standalone `Provider` substring (it also blocked the safe
  `byoProviderPicker` / `useThisProviderButton` / `activeProviderBadge`; staging a
  provider triggers no network).
- Removed the `Connect`/`connect`, `Verify`, and `Cancel` substrings — no dangerous
  control is named by them (mail uses "Test Connection", still blocked by `Test`).
- Replaced bare `Send`/`send` with **quote-anchored** forbids (`"Send"`,
  `"Send now"`, `"Send anyway"`) that block `label="Send"` /
  `role=button[name="Send"]` (the real dispatch buttons have no AX id) but not
  `id=managedSendCodeButton`.
- Added an explicit `Disconnect` forbid (previously caught by `Connect`).

Still forbidden so a hunt can never sign out, open a real browser, or send/draft:
`managedSignOutButton`, `getAPIKeyButton` / "Get an API key" (NOT hunt-gated —
opens a real browser), and `useManagedInference`.

Because the macOS substring selectors can resolve short values like `Q` or
`Fo` to unsafe menu items, this config forbids `menu=` and `text=` selectors.
Menu actions must use the explicit safe AX identifiers assigned in
`MenuBarController.swift`:

| Identifier | Menu item |
|---|---|
| `id=openSetupAssistant` | Setup Assistant… |
| `id=openSettings` | Settings… |
| `id=openActivityMenu` | Activity History… |
| `id=openFollowUpComposer` | New Follow-up from Transcript… (fixture-gated) |
| `id=openReviewWindow` | Review Drafts (N)… (fixture-gated) |
| `id=openBrowseMailbox` | Browse Mailbox… (fixture-gated) |
| `id=reportAProblem` | Report a Problem… (item 36 — assert-only; see below) |

### Review Drafts window tab switch (item 69)

The Review Drafts window has two tabs — **Drafts** (reviewable pending drafts)
and **Skipped** (the skip log). The tab switch carries stable AX identifiers so a
hunt can assert or drive it; switching tab is read-only (it changes only which
list is shown) and reaches no approve/deny/send/draft/dismiss/clear action, so it
is intentionally **not** in `forbiddenSelectors`. Neither identifier collides
with a forbidden substring (bare `Draft` is not forbidden — only `Draft anyway` /
`Draft reply` / `Draft follow-up` / `Draft a reply…` are — and `Skipped` is not
forbidden). The per-draft and per-skip actions inside each tab keep their existing
forbids (`Approve`, `Deny`, `Discard`, `Draft anyway`, `Clear`, `Dismiss`, …).

| Identifier | Control | Clickable in hunts |
|---|---|---|
| `id=reviewDraftsTab` | "Drafts (N)" tab of the review window | yes (read-only switch) |
| `id=reviewSkippedTab` | "Skipped (N)" tab of the review window | yes (read-only switch) |
| `id=pendingDraftRow` | A collapsed draft row in the Drafts list (item 82); clicking it expands/collapses that draft's detail inline | yes (read-only accordion toggle) |
| `id=openReviewDraftsFromComposer` | "Open Review Drafts" button shown in the Follow-up composer after a draft (item 81) | yes (read-only; same `openReviewWindow` action) |

The Drafts list is now a collapsible list (item 82): each draft is a compact
`pendingDraftRow` that expands to the full detail card on click, one at a time.
Expanding/collapsing is a **read-only view toggle** — exactly like
`reviewDraftsTab` — so `pendingDraftRow` is intentionally **not** in
`forbiddenSelectors`, and it collides with no forbidden substring (bare `Draft`
is not forbidden). The dangerous per-draft actions (`Approve` / `Deny` /
`Discard` / `Regenerate` / auto-send `Cancel` …) live inside the expanded detail
card and keep their existing forbids, so a hunt can open a row to assert the
detail appears but can never reach an action.

The composer's `openReviewDraftsFromComposer` button (item 81) only invokes the
already-allowed `openReviewWindow` action to front the Review Drafts window — no
state mutation — so it is intentionally **not** in `forbiddenSelectors`, and
neither its id nor its "Open Review Drafts" label collides with a forbidden
substring (`Open message from` is the only `Open …` forbid, and bare `Draft` is
not forbidden).

### Feedback / diagnostics controls (item 36)

The `menu-smoke` hunt asserts the **Report a Problem…** menu item is present, and
the `diagnostics-settings` hunt asserts the **Diagnostics** section renders on the
Settings → General tab. Both are **assert-only**; neither activates anything.

- `id=reportAProblem` (the menu item) is **not** in `forbiddenSelectors` so it can
  be asserted, mirroring the sign-in relaxation. Activation is safe anyway — hunt
  mode suppresses the mailto + reveal-in-Finder side effects (a click would only
  write a redacted diagnostics file) — and activation *by name* stays blocked by
  the `"Report a Problem"` label forbid.
- The **verbose-logging toggle** mutates persisted settings, so it stays fully
  forbidden (`verboseDiagnosticLoggingToggle` + `"Verbose diagnostic logging"`).
  To assert the section without touching it, the section's non-interactive
  descriptive text carries `id=diagnosticsSectionInfo` (read-only, not forbidden).

| Identifier | Control | Clickable in hunts |
|---|---|---|
| `id=reportAProblem` | "Report a Problem…" menu item | no (assert-only; label forbid blocks activation) |
| `id=diagnosticsSectionInfo` | Diagnostics section descriptive text (General tab) | n/a (non-interactive, assert-only) |

### Managed-inference sign-in / provider controls (items 56a, 59, 70)

The onboarding "Choose your AI" step and Settings → AI tab carry the
managed-inference sign-in surface. These SwiftUI controls set `accessibilityIdentifier`
values (resolved by `id=` selectors). In hunt mode sign-in and provisioning run
through a **deterministic offline fake** (see the fixture section above), so the
sign-in/provider hunts drive these controls end-to-end. The **Clickable in hunts**
column marks which are allowed by `forbiddenSelectors`:

| Identifier | Control | Clickable in hunts |
|---|---|---|
| `id=useManagedInference` | "Use Sentwise AI" (selects the managed provider) | no (forbidden; not needed) |
| `id=managedGoogleSignInButton` | "Continue with Google" (offline fake in hunt mode) | yes |
| `id=managedEmailField` | Email field for the sign-in code | yes (fill) |
| `id=managedSendCodeButton` | "Send sign-in code" (offline fake) | yes |
| `id=managedCodeField` | One-time-code field | assert-only |
| `id=managedVerifyButton` | "Verify & connect" (offline fake) | yes |
| `id=managedCancelBrowserSignIn` | "Cancel" (abort a browser-based Google sign-in) | assert-only |
| `id=managedSimulateGoogleCallback` | "Simulate browser sign-in" — **hunt-mode-only** control that completes the faked Google flow | yes |
| `id=managedSignOutButton` | "Sign out" of the managed account | no (forbidden) |
| `id=useOwnProviderDisclosure` | "Use your own AI provider instead" disclosure | (onboarding only) |
| `id=byoProviderPicker` | Bring-your-own provider picker | assert / stage |
| `id=useThisProviderButton` | "Use this provider" (activates the staged BYO provider) | assert |
| `id=openRouterConnectButton` | "Connect OpenRouter" (offline fake in hunt mode) | yes |
| `id=openRouterConnectedBadge` | "Connected" badge shown once OpenRouter is the active provider | assert-only |
| `id=getAPIKeyButton` | "Get an API key" (opens a REAL browser — not hunt-gated) | no (forbidden) |
| `id=activeProviderBadge` | "Active" badge on the provider currently drafting (non-interactive) | assert-only |

The sign-in/provider hunts target the **Settings → AI tab** (open Settings, click
the `label="AI"` toolbar tab). In the fixture, managed inference is the active
provider but not signed in, so all the sign-in controls render immediately; after a
faked sign-in the AI tab's Status row shows `activeProviderBadge`.

Window presence checks use `waitForSelector` with the exact AX label each
window sets via `setAccessibilityLabel` (`label=` is a step selector; it is
not recognized inside `assert`, so rely on `waitForSelector` failing the hunt
when the window never appears):

| AX label | Window |
|---|---|
| `label="New Follow-up"` | Follow-up composer |
| `label="Review Drafts"` | Review/approval window |
| `label="Browse Mailbox"` | Mailbox browser |
| `label="Sentwise Setup"` | Onboarding / setup assistant |
| `label="Sentwise Settings"` | Settings |
| `label="Activity History"` | Activity history |

## Selector dialect (macOS target)

- `statusItem` — press the app's menu bar status item (leaves the menu open)
- `id=<axIdentifier>` — accessibility identifier when the app exposes one
- `label="…"` — exact accessibility label match (steps only, not assertions).
  The Settings toolbar tabs are native `NSToolbarItem`s with no id, so
  `settings-window-tabs` clicks them by label (`label="General"`, `"Account"`,
  `"AI"`, `"Rules"`, `"About"`) — the visible toolbar title is the AX label.
- `role=button[name="Save"]` — AX role + accessible name
- `menu=<title>` — disabled by this repo's guardrails; use safe `id=` selectors
- `text="…"` — disabled by this repo's guardrails

Step kinds used by these hunts: `click` (selector), `fill` (`{ selector, value }`
— types text into a field, used for the managed email field), `assert`
(`{ visible: <selector> }`), `waitForSelector` (`{ selector, timeout }`), and
`scrollTo` (`{ selector }`, used to bring lower Settings content into view
without activating controls).

## CI (Prowl QA workflow)

`.github/workflows/prowl-qa.yml` runs the full hunt suite (`prowl ci --junit`)
against a fresh hunt-mode build on a **self-hosted macOS runner**. It checks out
the matching `prowl-tools/prowl` source tag (pinned via `PROWL_VERSION`), then
builds and links both the CLI and `prowl-macdriver` helper from that source. The
job fails fast with a clear message if the runner lacks Accessibility
permission.

Runner requirements (one-time, per machine):
- macOS with Xcode (the workflow builds both Sentwise and the Swift helper)
- **Accessibility** permission granted to the process hosting the runner agent
  (plus **Screen Recording** if failure screenshots are wanted)
- A logged-in GUI session — the hunts drive a real menu bar and real windows,
  so the runner cannot be a headless/SSH-only box
- Register the runner with labels `self-hosted, macOS`

The workflow is `workflow_dispatch`-only until the runner is proven; promote it
to a PR gate by uncommenting the `pull_request` trigger. Runs never execute
concurrently (a `concurrency` group serializes them — two hunts fighting over
one screen would flake).
