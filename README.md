# Sentwise

A native, local-first, open-source macOS menu-bar email assistant. It learns
your voice from your Sent mail, watches your inbox, drafts replies with a
pluggable LLM, and alerts you when a draft is ready to review and approve in
the app — so your drafts are waiting when you glance, not sitting on someone
else's server.

> **Status: early development.** The menu-bar app shell is in place. The email,
> voice-learning, and drafting features are being built out. See
> [`docs/backlog.md`](docs/backlog.md) for the roadmap and
> [`docs/resolved.md`](docs/resolved.md) for what's shipped.

## Why

Most AI email tools are cloud SaaS that read your mail on their servers and
charge per seat. Sentwise is the opposite: a native Mac app that runs on
your machine, stores your data locally, and uses whatever LLM you point it at
(including a fully local model). No subscription, no inbox custody.

## Principles

- **Local-first & private.** Your mail and voice profile stay on your Mac.
  Nothing leaves the machine except the LLM call you configure and control.
- **Bring your own key / provider.** Use Claude, OpenAI, or a local model
  (e.g. Ollama). Your keys live in the macOS Keychain.
- **Human-in-the-loop.** Every reply is drafted for your approval — nothing is
  sent without you.
- **Native, not a browser tab.** A real menu-bar app, installed from a signed
  DMG or Homebrew.

## Planned features

- Learns your writing voice from your Gmail Sent folder
- Watches your inbox and drafts replies while your Mac is awake
- Get alerted by a native macOS notification, then review and approve the full draft in the app
- Configurable: auto-send on approval, or save as a draft
- Pluggable LLM providers plus a local-model option
- Secrets stored in the macOS Keychain

Gmail is the first supported provider; Outlook/M365, IMAP/SMTP, and a Slack
approval channel are on the roadmap.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later (to build from source)

## Build from source

```bash
git clone https://github.com/michaeltookes/sentwise.git
cd sentwise/Sentwise
open Sentwise.xcodeproj
```

Select the **Sentwise** scheme and run. To build and test from the command
line:

```bash
cd Sentwise
xcodebuild test -project Sentwise.xcodeproj -scheme Sentwise \
  -destination 'platform=macOS'
```

A few integration tests verify the real IMAP/SMTP path against a live mailbox.
They are credential-gated and skip by default; see
[`docs/live-verification.md`](docs/live-verification.md) to run them.

Signed DMG and Homebrew distribution are added at the distribution milestone
(see the backlog).

## Contributing

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for build,
test, and pull-request guidelines, and
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © 2026 Michael Tookes
