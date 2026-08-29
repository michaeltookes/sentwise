# Post-call follow-ups

Sentwise drafts the follow-up email after a call from its transcript, in
your learned voice, and hands it to the same review → approve → send/save flow
as inbox replies. There is no bot in your meetings and no audio capture: the
transcript arrives as a file or a paste, and everything stays on your machine
except the LLM call you control.

## Draft a follow-up from a transcript

Open **New Follow-up from Transcript…** from the menu bar (available once an
email account is connected). In the composer you can:

- **Paste** the transcript text directly, or
- **Choose a file**, or
- **Drag and drop** a transcript file onto the editor.

Supported file formats are the ones Zoom, Teams, and notetakers export:
`.txt`, `.md`, `.vtt` (WebVTT), and `.srt` (SubRip). Cue numbers and timestamps
are stripped automatically, and speaker labels are preserved — WebVTT `<v Name>`
voice tags and `Name:` prefixes both become attributed turns so action items can
be tied to the right owner. Transcripts without speaker labels work too; the
draft simply avoids guessing who owns what.

Optionally enter **recipients** (comma-separated; `Name <email>` is accepted) and
a **subject** before drafting. Both are optional here — recipients can also be
added in review. Click **Draft follow-up** and the draft appears in
**Review Drafts**. The composer confirms with a green "Follow-up drafted" line
and an **Open Review Drafts** button beside it, so you can jump straight to the
review window to approve the draft without going back up to the menu bar.

The generated email contains, when the call supports it: a brief recap, the
agreed next steps / action items with an owner named for each, and a proposed
next meeting. It never invents commitments, owners, or dates that the transcript
doesn't support.

## Watched folder (automatic)

To draft follow-ups without pasting anything, point Sentwise at a folder —
for example Zoom's local recording directory. Open **Settings → General →
Post-call follow-ups**, turn on **Watch a folder for new transcripts**, and
**Choose…** the folder.

When a new transcript file appears in that folder, Sentwise drafts a
follow-up automatically and adds it to Review Drafts. The feature is **off by
default**. Files already in the folder when watching starts are left alone —
only files that appear afterwards trigger a draft — and your files are never
moved or deleted. An automatically drafted follow-up has no recipients yet
(recipient auto-fill from your calendar is a separate, later capability), so add
them in review before approving.

## Recipients and approval

A follow-up is an *authored* draft: it has no incoming message to reply to, so
it does not thread, and its recipients come from you. The Drafts tab is a
collapsible list: each draft is a compact row (sender, subject, and a status
chip), and clicking one expands its full detail inline while collapsing any other
open row — so the list scrolls smoothly and you read one draft at a time. A
**search field** above the list filters the visible tab by sender and subject as
you type (matching the decoded subject, not the raw header); the tab label shows
"N of M" while a filter is active, and clearing the field restores the full list.
A
follow-up that still needs recipients shows an **Add recipients** chip on its
row; expand it and the follow-up detail shows an editable **To** field in place
of the incoming-message column. Edit the recipients there; the draft can't be
approved until it has at least one. Approving then sends or saves it exactly like
any other draft, honoring your **On approve** setting (save as draft or send
immediately) and the auto-send undo window.

## Long calls

A two-hour call produces a draft, not an error. When a transcript is longer than
the model's single-pass budget, Sentwise summarizes it chunk-by-chunk first —
extracting decisions, action items with owners, deadlines, and any next meeting —
then drafts the follow-up from that distilled summary, keeping the request within
the model's context window.

## Which model is used

Follow-ups go through the same pluggable LLM layer as reply drafting, so they
work with whatever provider you've connected: the managed default, a
BYO-key cloud provider, or a fully local model (see
[Local models](local-models.md)). Nothing about the follow-up path is
provider-specific.

## How it fits the architecture

Transcript acquisition is deliberately pluggable, the way LLM providers are. A
`TranscriptSource` produces `IngestedTranscript` values that feed one shared
drafting pipeline; the watched folder is the first source, and future sources
(platform APIs, native on-device capture) conform the same way without changing
the pipeline. Paste and file imports are one-shot and build an ingested
transcript directly.

From the drafted body onward, the follow-up reuses the existing plumbing
unchanged: it becomes a pending draft, fires the same native notification, and
dispatches through the same send/save-as-draft path as inbox replies — an
authored draft with user-supplied recipients and no reply threading, rather than
a parallel pipeline.
