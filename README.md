# Sentwise

**Your follow-up email is drafted before you're back from the coffee machine.**

Sentwise is a native, local-first macOS menu-bar assistant that learns your
writing voice from your own Sent mail and drafts email on your behalf — then
alerts you when a draft is ready so you can read it in full and approve it in
the app. Sentwise does not store your mail, voice profile, or call transcripts
on Sentwise servers. When Sentwise drafts or learns your voice, only the text
needed for that request transits the managed, stateless, zero-retention
inference proxy.

The flagship workflow is the **post-call follow-up**: when a call ends, drop in
the transcript and Sentwise drafts the next-steps email in your voice, addressed
and ready to send. It also watches your inbox and drafts replies to mail that
deserves one. You stay in the loop — every draft waits for your approval.

> **Release note:** This README describes Sentwise 1.0.0, the current signed DMG
> and Homebrew package. Sentwise AI is included with subscriptions; no
> user-managed API keys are required.

## Why Sentwise

Most AI email tools are cloud services that read your mail on their servers,
store your calls indefinitely, and train their models on your data. Sentwise is
built the opposite way:

- **No Sentwise storage, no Sentwise training.** Managed drafting runs through a
  **stateless, zero-retention** inference proxy — request and response bodies are
  held in memory only and never logged or kept by Sentwise.
- **No bot in your meetings.** Sentwise never joins your calls. Transcripts
  arrive as a paste, file, or local watched folder (meeting-platform pickup and
  on-device capture are on the roadmap), not as a cloud meeting archive;
  transcript text is sent only when Sentwise AI drafts from it.
- **A send-ready email, not a summary.** The output is a finished draft in
  *your* learned voice, sent from *your* mailbox — not a note stranded in a
  separate app.
- **Native, not a browser tab.** A real menu-bar Mac app, installed from a
  signed DMG or Homebrew and kept current with automatic updates.

## What it does

- **Post-call follow-ups** — ingest a call transcript (paste, file, or a watched
  folder that picks up new exports automatically) and draft the next-steps email
  in your voice, with recap, action items, and a proposed next step.
- **Inbox reply drafting** — Trial, Pro, and Unlimited can watch your Gmail inbox
  while your Mac is awake and offer drafts for mail worth answering. Starter
  focuses on transcript follow-ups and on-demand drafting without background
  inbox watching.
- **Learns your voice** from your Gmail Sent folder, and re-learns on demand.
- **Review and approve in the app** — a native macOS notification tells you a draft
  is ready; you open the Review Drafts window, read the full draft, and approve
  it deliberately. Approving either **saves it to your Gmail Drafts** or
  **sends it** (your choice), with an optional undo window on auto-send.
- **Optional signatures** — set one yourself or let Sentwise suggest one from
  your Sent mail.
- **Report a Problem** from the menu bar packages a redacted diagnostic log — no
  email content — so issues are fixable without you sending anything sensitive.

## How you connect and pay

- **Sign in and go.** Create an account; your 14-day trial starts on the first
  managed inference request, including voice learning or drafting — no API key,
  no provider billing, drafting included. Sentwise AI is the only shipped
  inference path in 1.0.
- **Subscribe when the trial ends.** Starter is $9/month for 30 follow-ups and
  no background inbox watching, Pro is $19/month for 120 follow-ups, and
  Unlimited is $39/month for fair-use unlimited follow-ups. Checkout and plan
  changes start in **Settings → Subscription**. Active subscription management
  and cancellation open Paddle's secure billing portal in your browser.
- **Connect Gmail** by pasting your address and a 16-character Google **app
  password** (requires 2-Step Verification) — no Google Cloud console, no OAuth
  setup.
  For Google Workspace accounts, your admin must allow IMAP and app passwords.

The source is public and self-compilers are welcome. The signed, auto-updating
binary uses your Sentwise account to license managed drafting.

## Quickstart

1. **Install.**
   - Download the latest DMG from [Releases](https://github.com/michaeltookes/sentwise/releases/latest) and drag Sentwise to Applications, **or**
   - `brew install --cask michaeltookes/tap/sentwise`

   The current package installs Sentwise 1.0.0. Sentwise lives in your menu bar
   (no Dock icon) and keeps itself up to date.

2. **Connect your Gmail.** You'll need a Google **app password** (Gmail's
   per-app credential), which requires 2-Step Verification on your account:
   1. Turn on 2-Step Verification at <https://myaccount.google.com/security>.
   2. Create an app password at <https://myaccount.google.com/apppasswords>;
      for Google Workspace accounts, your admin must allow IMAP and app
      passwords, and security-key-only policies can block app passwords even
      after 2-Step Verification is on.
   3. Paste your email address and the 16-character password into Sentwise.

   ![Google Account → App passwords: name it "Sentwise" and click Create to get a 16-character password](docs/images/app-password.png)

   Google then shows a 16-character password — copy it and paste it, with your
   email address, into Sentwise's Add account fields:

   ![Sentwise Settings → Account: paste your email address and app password into the Add account fields](docs/images/account-connect.png)

3. **Sign in to Sentwise AI.** After Gmail connects, sign in with your email.
   Drafting is included, and your 14-day trial starts when Sentwise AI is first
   used, whether for voice learning or drafting — no key to paste.

4. **Learn your voice.** Sentwise samples your Sent mail to build a private voice
   profile. The profile is stored locally; the sampled text needed for profiling
   transits the managed zero-retention inference proxy. This starts the trial
   clock.

5. **Get your first draft.** Click **Finish** to complete onboarding and start
   the inbox watcher, then send a test email to the connected Gmail account from
   another address (or drop in a call transcript via **New Follow-up from
   Transcript…**). When the draft is ready, the notification banner appears —
   open it, read the full draft in Review Drafts, add recipients if you started
   from a transcript without them, and approve.

   ![Review Drafts: the incoming message beside the proposed reply, with Deny and Approve](docs/images/review-approve.png)

## Privacy in one screen

- **What Sentwise stores locally:** your learned voice profile, settings, pending
  drafts, and transcript files you provide. Sentwise does not store your email
  or call content on its servers.
- **What leaves, and when:** Sentwise AI requests include only the content needed
  for the job — Sent-mail samples for voice learning, incoming email text for
  replies, or transcript text for follow-ups. That content moves through a
  **stateless, zero-retention** proxy; request and response bodies are held in
  memory only and are not logged or retained by Sentwise.
- **What the account stores:** your account email, trial/subscription state,
  usage counters, and billing references — **never your email or call content.**
- **What Sentwise never does:** your content is never logged or stored on
  Sentwise servers and never used by Sentwise to train models.

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

Sentwise is in active development after launch. On the roadmap: calendar-aware
follow-up recipients, automatic transcript pickup from meeting platforms,
on-device call capture and transcription, a Slack approval channel, and
Outlook/M365 support.

See [`docs/backlog.md`](docs/backlog.md) for the full roadmap and
[`docs/resolved.md`](docs/resolved.md) for what's already shipped.

## Contributing

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for build,
test, and pull-request guidelines, and
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © 2026 Michael Tookes
