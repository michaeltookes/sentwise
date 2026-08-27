# Sentwise

**Your follow-up email is drafted before you're back from the coffee machine.**

Sentwise is a native, local-first macOS menu-bar assistant that learns your
writing voice from your own Sent mail and drafts email on your behalf — then
alerts you when a draft is ready so you can read it in full and approve it in
the app. Your mail, your voice profile, and your call transcripts stay on your
Mac. Nothing is stored on anyone's server, and nothing you write is ever used
as training data.

The flagship workflow is the **post-call follow-up**: when a call ends, drop in
the transcript and Sentwise drafts the next-steps email in your voice, addressed
and ready to send. It also watches your inbox and drafts replies to mail that
deserves one. You stay in the loop — every draft waits for your approval.

## Why Sentwise

Most AI email tools are cloud services that read your mail on their servers,
store your calls indefinitely, and train their models on your data. Sentwise is
built the opposite way:

- **Nothing stored, nothing trained on.** Drafting runs through a **stateless,
  zero-retention** inference proxy — your request is held in memory for the
  length of the call and never logged or kept. Or bring your own key / run a
  local model and take us out of the loop entirely.
- **No bot in your meetings.** Sentwise never joins your calls. Transcripts
  arrive as a file or a paste (with automatic pickup and on-device capture on
  the roadmap), and stay on your Mac.
- **A send-ready email, not a summary.** The output is a finished draft in
  *your* learned voice, sent from *your* mailbox — not a note stranded in a
  separate app.
- **Native, not a browser tab.** A real menu-bar Mac app, installed from a
  signed DMG or Homebrew and kept current with automatic updates.

## What it does

- **Post-call follow-ups** — ingest a call transcript (paste, file, or a watched
  folder that picks up new exports automatically) and draft the next-steps email
  in your voice, with recap, action items, and a proposed next step.
- **Inbox reply drafting** — watches your Gmail inbox while your Mac is awake and
  drafts replies to mail worth answering.
- **Learns your voice** from your Gmail Sent folder, and re-learns on demand.
- **Review and approve in the app** — a native macOS notification tells you a
  draft is ready; you open the Review Drafts window, read the full draft, and
  approve it deliberately. Approving either **saves it to your Gmail Drafts** or
  **sends it** (your choice), with an optional undo window on auto-send.
- **Your signature**, applied automatically — set it yourself or let Sentwise
  suggest one from your Sent mail.
- **Report a Problem** from the menu bar packages a redacted diagnostic log — no
  email content — so issues are fixable without you sending anything sensitive.

## How you connect and pay

- **Sign in and go.** Create an account, and your 14-day trial starts — no API
  key, no provider billing, drafting included. Managed inference is the default;
  you never touch a key.
- **Or bring your own.** Prefer to run it yourself? Point Sentwise at your own
  provider key (via OpenRouter and others) or a **local model** (e.g. Ollama).
  On this path, drafting never touches our servers at all. Your keys live in the
  macOS Keychain.
- **Connect Gmail** by pasting your address and a 16-character Google **app
  password** (requires 2-Step Verification) — no Google Cloud console, no OAuth
  setup.

After the trial, Sentwise is a subscription with the AI included. The source is
public — self-compilers are welcome; the signed, auto-updating binary is
licensed to your account.

## Quickstart

> **Packaged install and the hosted trial arrive at the 1.0 release.** Today you
> can run Sentwise by [building from source](#build-from-source); the steps
> below are the 1.0 experience. Until then, start at step 2 after building.

1. **Install.**
   - Download the DMG — *link available at the 1.0 release ([Releases](https://github.com/michaeltookes/sentwise/releases))* — and drag Sentwise to Applications, **or**
   - `brew install --cask sentwise` — *available at launch.*

   Sentwise lives in your menu bar (no Dock icon) and keeps itself up to date.

2. **Sign in and start your trial.** Open Sentwise from the menu bar, sign in
   with your email, and your 14-day trial begins. Drafting is included — no key
   to paste.

   *(Prefer to bring your own key or a local model? Choose that provider in
   Settings instead — see [Bring your own provider](#bring-your-own-provider).)*

3. **Connect your Gmail.** You'll need a Google **app password** (Gmail's
   per-app credential), which requires 2-Step Verification on your account:
   1. Turn on 2-Step Verification at <https://myaccount.google.com/security>.
   2. Create an app password at <https://myaccount.google.com/apppasswords>.
   3. Paste your email address and the 16-character password into Sentwise.

   <!-- SCREENSHOT: Google "App passwords" page with a generated 16-char password -->

   ![Sentwise Settings → Account: paste your email address and app password into the Add account fields](docs/images/account-connect.png)

4. **Learn your voice.** Sentwise samples your Sent mail to build a private voice
   profile. This stays on your Mac.

5. **Get your first draft.** Send yourself a test email (or drop in a call
   transcript via **New Follow-up from Transcript…**). When the draft is ready,
   the notification banner appears — open it, read the full draft in Review
   Drafts, and approve.

   <!-- SCREENSHOT: notification banner "A draft is ready" (Open / Close) -->
   <!-- SCREENSHOT: Review Drafts window showing a drafted reply with Approve -->

### Bring your own provider

Sentwise's managed inference is the default, but the BYO path is a first-class
option for power users and the privacy-maximal:

- In **Settings → AI provider**, choose your provider and paste your key (stored
  in the Keychain), or point Sentwise at a **local model** (e.g. Ollama) for
  fully on-device drafting.
- On this path, drafting requests go directly from your Mac to the provider you
  chose — never through our proxy.

## Privacy in one screen

- **What stays on your Mac:** your mail, your learned voice profile, and your
  call transcripts.
- **What leaves, and when:** only the drafting request itself — and only to the
  inference endpoint. On managed inference that's a **stateless, zero-retention**
  proxy (held in memory, never logged or stored); on BYO-key/local it's the
  provider you chose, or nowhere at all with a local model.
- **What the account stores:** your email, subscription state, and usage
  counters — **never your email or call content.**
- **What is never done:** your content is never stored on our servers and never
  used to train any model.

## Requirements

- macOS 14 (Sonoma) or later
- A Gmail account with 2-Step Verification (for the app password)
- Xcode 16 or later (only to build from source)

## Build from source

```bash
git clone https://github.com/michaeltookes/sentwise.git
cd sentwise/Sentwise
open Sentwise.xcodeproj
```

Select the **Sentwise** scheme and run. To build and test from the command line:

```bash
cd Sentwise
xcodebuild test -project Sentwise.xcodeproj -scheme Sentwise \
  -destination 'platform=macOS'
```

A few integration tests verify the real IMAP/SMTP path against a live mailbox.
They are credential-gated and skip by default; see
[`docs/live-verification.md`](docs/live-verification.md) to run them.

## Roadmap

Sentwise is in active development toward its 1.0 release. Shipping next:
packaged distribution (signed DMG + Homebrew cask), subscription checkout, and a
landing page. On the longer roadmap: calendar-aware follow-up recipients,
automatic transcript pickup from meeting platforms, on-device call capture and
transcription, a Slack approval channel, and Outlook/M365 support.

See [`docs/backlog.md`](docs/backlog.md) for the full roadmap and
[`docs/resolved.md`](docs/resolved.md) for what's already shipped.

## Contributing

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for build,
test, and pull-request guidelines, and
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © 2026 Michael Tookes
