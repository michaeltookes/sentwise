# Feedback & diagnostics (Report a Problem)

Sentwise can file an actionable bug report **without leaking your email
content**. The load-bearing piece is a **redacted diagnostics bundle** that only
the app can produce — a web form can't read your local unified log — so the
feedback path lives in the app and is routed to the maintainer by email
(backlog item 36). A prettier landing-page form for general/feature feedback is
tracked separately with the marketing site (item 57) and complements this path.

## Reporting a problem

**Menu bar → Report a Problem…** does two things:

1. **Generates a redacted diagnostics bundle**, saves it as
   `Sentwise-Diagnostics-<timestamp>.txt` in your Downloads folder (the
   temporary directory is the fallback), and **reveals it in Finder**.
2. **Opens your mail client** with a pre-filled email to
   **`feedback@sentwise.ai`**. The subject and body carry the app version and
   your macOS version plus a short template, and the body reminds you to attach
   the file just revealed in Finder — `mailto:` cannot attach a file itself, so
   the reveal-in-Finder + instruction is the flow.

If Sentwise cannot write the bundle to Downloads or the temporary fallback
(for example, because the disk is full or both folders are unavailable), it
shows an alert instead of silently doing nothing or opening an email without the
bundle.

If the bundle is written but macOS cannot open a mail composer, Sentwise still
reveals the file and shows an alert with the `feedback@sentwise.ai` address so
you can send the attachment manually.

The feedback address is baked into the app and is the app's stated contact until
the marketing site ships. (Standing up the inbox as a monitored mailbox is a
separate launch prerequisite — item 74.)

## What's in the bundle — and what's never in it

The bundle is **default-safe**: assume a stranger will paste it into a public
issue. It contains:

- **Environment context** (non-PII): app version and build, macOS version,
  hardware model identifier, the selected **LLM provider *kind*** (e.g.
  `managed` — never a key), send behavior, poll interval, notification-permission
  state, whether verbose logging is on, and whether a transcript folder is being
  watched (the boolean only — never the folder path).
- **Recent app log entries** from the unified log, read via `OSLogStore` scoped
  to the system log and the `com.tookes.Sentwise` subsystem, covering the last
  24 hours across Sentwise process launches. Collection is bounded by entry
  count and captured message bytes so report generation stays finite.

It **never** contains message bodies, subjects, or recipients; credentials;
your account or mailbox email; the mail host or username; tokens; or the
watched-folder path.

Two layers keep it safe:

- **The app never logs mail content** at any level — addresses, subjects, and
  bodies are not passed to the logger.
- **A redaction pass** runs over the *entire assembled report* (context header
  included) as belt-and-suspenders: email addresses, including internal-domain
  forms, become `[redacted-email]`; filesystem paths and `file://` URLs become
  `[redacted-path]`; and bearer tokens / secret key-value assignments, including
  JSON-quoted and compound-key forms, become `[redacted-token]`. So even an
  accidentally-logged address, token, or local path is scrubbed before the file
  is written.

This is developer diagnostics from `os_log`, deliberately kept **distinct from
the user-facing Activity History** (item 21) — they serve different audiences.

## Verbose diagnostic logging

**Settings → General → Diagnostics → "Verbose diagnostic logging"** raises log
detail. It is **off (normal) by default** and is persisted. When on, the app
emits additional non-personal `debug`/`info` detail, and those lower-level
entries are included in the bundle so a report is richer. The setting never
changes what mail content is logged (that is never logged at any level). Turn it
on, reproduce the bug, then use **Report a Problem**.

## How it's built (for contributors)

The feature is composed of small, pure, injectable pieces so the privacy-
critical logic is unit-tested without touching the real log store or launching
Finder/Mail:

- `DiagnosticsRedactor` — the pure scrub (emails, filesystem paths, bearer
  tokens, secret assignments).
- `DiagnosticsContext` — the non-PII environment block and its renderer.
- `DiagnosticsLogReading` / `OSLogStoreDiagnosticsReader` — reads the app's own
  entries; a fake reader feeds tests injected log lines.
- `DiagnosticsReportBuilder` — assembles context + logs and runs the whole thing
  through the redactor.
- `FeedbackMailComposer` — builds the percent-encoded `mailto:` URL.
- `DiagnosticsActionRouting` / `SystemDiagnosticsActionRouter` — the
  Finder-reveal and URL-open seam (a recording fake replaces it in tests).
- `DiagnosticLog` — the global `isVerbose` flag (mirrored from
  `Settings.verboseDiagnosticLogging`) and a `verbose(_:)` helper.

`AppState.reportAProblem(...)` snapshots the live state on the main actor, then
collects logs, builds/redacts the report, and writes the bundle on a utility
task before returning to the main actor for Finder/Mail side effects. In Prowl
hunt mode the bundle is still written but the Finder/Mail side effects are
suppressed, and the menu action and verbose toggle are open-and-assert forbidden
in `.prowl/config.yml`.

The verbose-logging preference is a purely additive `Settings` field introduced
at **schema version 17** (older files decode it to off); the terminal launch
migration stamps the new version, leaving the earlier migration chain unchanged.
