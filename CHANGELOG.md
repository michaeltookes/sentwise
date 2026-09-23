# Changelog

All notable changes to Sentwise are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-22

Sentwise 1.0 — the first full release. Sign in, start a 14-day free trial, and
Sentwise drafts email in your voice with nothing to configure: AI drafting is
bundled into the subscription, and your mail, voice profile, and transcripts
never leave your Mac except as stateless, zero-retention managed inference calls
for voice learning and drafting.

### Added

- **Subscriptions with bundled AI drafting** — no API keys, ever. Start a
  14-day free trial (no card required), then pick Starter, Pro, or Unlimited —
  each with a monthly draft allotment. Checkout and plan changes start in
  Settings → Subscription; active subscription management and cancellation open
  Paddle's secure billing portal in your browser.
- **Multiple mail accounts** (Pro & Unlimited) — connect more than one mailbox.
  Review Drafts and Browse Mailbox get account pickers and per-account badges,
  so every draft is clearly attributed to the mailbox it belongs to.
- **Draft-on-click inbox watching** — when a reply-worthy email arrives,
  Sentwise now *offers* a draft ("Reply-worthy: … — draft a reply?") instead of
  spending a draft automatically. Click to generate. Automatic drafting is
  still there as an opt-in — flip the toggle, or list specific senders and
  domains that should always be auto-drafted, with an optional monthly budget cap
  to limit how much of your allotment automation can use. Starter plans focus on
  transcript follow-ups and on-demand drafting (no background watching).
- **Usage insights** — a local Analytics pane in Settings: drafting activity,
  approval rate, and your most common deny reasons. All of it stays on your
  Mac.
- **Answer "Needs your input" in place** — when a draft needs a detail only you
  know, type the answer right in the card and Sentwise re-drafts.
- **Report a Problem** — send feedback with an optional redacted diagnostics
  log to feedback@sentwise.ai, straight from the app.
- **Search & filter in Review Drafts**, plus a collapsible list — rows expand
  into full drafts, and long lists finally scroll the way you expect.
- **Optional email signatures** — set a signature yourself or ask Sentwise to
  suggest one from your Sent mail.
- **Google Workspace connection guidance** — when an administrator blocks app
  passwords or IMAP, Sentwise explains the policy, offers copy-ready admin
  guidance, and lets users ask to be notified when Sign in with Google ships.
- **Native Settings window** — proper macOS toolbar tabs, including an About
  pane.

### Changed

- **Mailbox-first onboarding** — setup is now: connect your mailbox, sign in to
  Sentwise AI, choose approval behavior, learn your voice, go. Model and
  provider choices are gone from onboarding.
- **Approval always happens in the app** — the draft notification is now an
  Open/Close alert; you approve in Review Drafts after reading the full draft,
  never blind from a banner.
- **Review Drafts redesigned**, and watcher drafts pass a relevance gate so
  newsletters, receipts, and other transactional mail no longer produce drafts.
- **Managed drafting is the only AI path** — the bring-your-own-key and
  local-model options were removed from setup and Settings.
- **Production services** — accounts now run on production auth
  (clerk.sentwise.ai) and live billing.

### Fixed

- Switching pricing tiers no longer gets stuck after closing a checkout
  overlay.
- Usage copy correctly describes the monthly window and shows the real reset
  date.
- A watcher IMAP crash in rare fetch-failure cases.
- Disabled notification permission is surfaced prominently instead of failing
  silently (notifications are the primary approval channel).
- Disconnecting an account (or "erase all local data") fully purges local mail
  artifacts.

### Security

- Two hardening passes (app and service) from the September security audit,
  covering the checkout flow, service auth, and local data handling.

## [0.1.2] - 2026-08-19

### Fixed

- **App passwords paste correctly now** — pasting an app password exactly as your provider displays it (grouped like `xxxx xxxx xxxx xxxx`) works: interior spaces are stripped automatically for Gmail, Yahoo, AOL, AT&T, and iCloud accounts. Previously only leading/trailing spaces were removed and setup failed with a confusing authentication error.

### Changed

- **Setup explains what's blocking Continue** — while the Continue button is disabled on the mail-account and AI-provider steps, visible helper text now says "Run Test Connection to continue" instead of leaving the button silently grayed out.
- **Clearer app-password guidance** — the per-provider setup instructions now spell out which kind of app password you need (e.g. "a GOOGLE app password, not an Apple one" for Gmail) — the two look identical and are easy to mix up.

## [0.1.1] - 2026-08-14

### Fixed

- **v0.1.0 crashed at launch** — the exported app was missing its framework search path, so it could not load the bundled Sparkle updater and aborted immediately. If you installed v0.1.0, update to this release (`brew upgrade --cask sentwise` or download the new DMG); it launches correctly.

### Changed

- **New app icon** — the Sentwise owl: an envelope that looks back at you, with a hand-tuned variant so it stays legible at the smallest sizes.
- **Refreshed DMG installer artwork** to match the new brand.

## [0.1.0] - 2026-08-14

Initial release.

### Added

- **Post-call follow-up workflow** — paste a call transcript, drop a `.txt`/`.md`/`.vtt`/`.srt` file, or point Sentwise at a watched folder (e.g. Zoom's local recording directory): it drafts the next-steps follow-up email in your voice — recap, action items with owners, proposed next meeting — ready for one-tap approval.
- **Voice learning** — Sentwise studies your Sent mail so drafts sound like you, not like an AI.
- **Inbox reply drafting** — watches your inbox and drafts replies to messages worth answering, with automatic filtering of newsletters, notifications, and no-reply senders.
- **One-tap approval** — native macOS notifications and a review window; approve, edit, or deny every draft. Nothing ever sends without you.
- **Send or save-as-draft** — your choice on approval: send immediately (with a configurable undo window) or save to your provider's Drafts folder.
- **Safety guards** — stale-thread detection blocks replies to conversations that moved on; low-confidence drafts are flagged for your input instead of guessing; offline approvals queue durably and dispatch on reconnect.
- **Supported IMAP mailboxes** — connect with your email address and an app password. Gmail and AT&T/Yahoo are verified live end to end; custom IMAP hosts are supported when their SMTP endpoint follows the derived `smtp.` host on implicit-TLS port 465.
- **Bring-your-own AI** — pluggable providers (Anthropic, OpenAI, and any OpenAI-compatible endpoint including local runtimes like Ollama), with your key stored in the macOS Keychain.
- **Mailbox cleanup tools** — a browser with search and safe bulk cleanup that can drain even huge, neglected inboxes without ever bulk-downloading them.
- **Activity history** — a local, metadata-only log of everything the assistant did and why.
- **Private by design** — local-first storage keeps settings, history, and secrets on your Mac. When you use a remote AI provider, Sentwise sends the relevant mail content, transcript text, and voice profile only to the provider you configure.
- **Signed, notarized, auto-updating** — Developer ID–signed DMG with Sparkle auto-update and a Homebrew cask (`brew install --cask michaeltookes/tap/sentwise`).

[1.0.0]: https://github.com/michaeltookes/sentwise/compare/v0.1.2...v1.0.0
[0.1.2]: https://github.com/michaeltookes/sentwise/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/michaeltookes/sentwise/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/michaeltookes/sentwise/releases/tag/v0.1.0
