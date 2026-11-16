---
title: "How do you follow up after every sales call, in your own voice, without a meeting bot?"
description: "Sentwise 0.2.4 for macOS drafts the post-call follow-up from a transcript you already have, in the voice it learned from your Sent mail. Here is the setup, what it costs, and what it does not do."
date: 2026-11-16
author: Sentwise
tags: [follow-up-email, sales, macos, email-drafting]
version: 0.2.4
---

The follow-up after a call is the email most likely to go out late or not at all. The next call starts, the day fills up, and by evening the recap is a chore done badly. Most tools that fix this put a bot in the meeting and keep the recording in their cloud. What you get back is a summary, and you still have to turn it into an email.

Sentwise takes the other route. You hand it a transcript you already have, it drafts the next-steps email in your voice, and the draft waits for you to read and approve it. No bot joins the call. This post covers the setup in Sentwise 0.2.4, the current release.

## What do you need before you start?

- A Mac running macOS 14 (Sonoma) or later.
- A Gmail account with 2-Step Verification on. Sentwise connects with your address and a Google app password.
- A transcript. Sentwise does not record or transcribe calls. It reads the exports Zoom, Teams and note-taking tools produce: `.txt`, `.md`, `.vtt` and `.srt` files, or pasted text.

If you do not keep transcripts of your calls, the post-call workflow does not apply to you yet.

## How do you install it and connect your mailbox?

Download the DMG from https://sentwise.ai/download (the Homebrew cask `brew install --cask michaeltookes/tap/sentwise` installs the same build). Sentwise lives in the menu bar and has no Dock icon.

1. Create an app password at https://myaccount.google.com/apppasswords. For Google Workspace accounts, your admin must allow IMAP and app passwords.
2. Paste your email address and the 16-character password into Sentwise.
3. Sign in to your Sentwise account with your email. Drafting is included, so there is no API key to paste.
4. Let Sentwise learn your voice. It samples your Sent mail once and builds a voice profile that is stored on your Mac. You can re-learn it at any time.

Your 14-day trial starts the first time Sentwise AI is used, which is usually voice learning. No card is needed.

## How does the follow-up get written?

Open **New Follow-up from Transcript…** from the menu bar. Paste the transcript, choose a file, or drag one onto the editor. Recipients and subject are optional here. Click **Draft follow-up** and the draft appears in Review Drafts.

To skip the paste, turn on **Settings → General → Post-call follow-ups → Watch a folder for new transcripts** and choose a folder, for example Zoom's local recording directory. Each new transcript file that appears in that folder gets a draft. The setting is off by default, files already in the folder are ignored, and your files are never moved or deleted.

The draft contains, when the call supports it, a brief recap, the agreed next steps with an owner named for each, and a proposed next meeting. Speaker labels in the transcript are used to work out who is you and who the recipient is, so the greeting goes to the right person and action items go to the right owners. Sentwise does not invent commitments, owners or dates the transcript does not support. A two-hour call produces a draft, not an error.

## Who approves the email?

You do. A macOS notification tells you a draft is ready, but approval happens in the Review Drafts window after you read the full draft. A follow-up needs at least one recipient before it can be approved. Approving either saves the email to your Gmail Drafts or sends it, whichever you set under **On approve**, with an undo window on send. Nothing goes out without that step.

## What leaves your Mac?

Stored mail, your voice profile and your transcripts stay on your Mac. Only the text needed for a request, such as the transcript for a follow-up, passes through Sentwise's stateless proxy. Sentwise does not log or retain request or response bodies, and managed drafts do not train models.

## What does it cost?

| Plan | Price | Follow-ups | Mailboxes | Inbox watching |
|---|---|---|---|---|
| Trial | 14 days, no card | trial allotment | 2 | yes |
| Starter | $9/month | 30 | 1 | no |
| Pro | $19/month | 120 | 2 | yes |
| Unlimited | $39/month | unlimited (fair use) | up to 5 | yes |

Unlimited refers to follow-up volume, not accounts. AI drafting is included in every plan.

## What is new in 0.2.4?

It is a small release about trust in the download. The disk image is now signed with Genkei Labs' Developer ID before it is notarized and stapled, and the release pipeline refuses to publish a DMG that Gatekeeper does not accept. Builds keep supporting macOS 14. The rest is wording. The Sign in with Microsoft consent text is clearer (that sign-in is still switched off), and the "your sign-in expired" message reads the same for Google and Microsoft accounts. The full list is in the [changelog](https://github.com/michaeltookes/sentwise/blob/main/CHANGELOG.md).

## What does it not do?

- It does not record or transcribe calls.
- It works with Gmail today. Outlook and Microsoft 365 accounts cannot be connected yet.
- It does not pick up transcripts from Zoom or Teams by itself. Use a paste, a file, or a watched folder.
- It runs on Mac only, on macOS 14 or later.

Try it at https://sentwise.ai/download. Questions or something broken: support@sentwise.ai.
