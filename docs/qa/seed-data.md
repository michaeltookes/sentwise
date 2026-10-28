# Sentwise — QA seed data

**Milestone:** M6 Sign-in first (`TC-M6-01`–`TC-M6-11`)  
**Rule:** this file records fixture names and states only. It never records a real mailbox address, password, app password, access token, refresh token, tenant ID, client ID or recovery code. Actual addresses and credentials live in Lucius' secret store; reports and assets use the fixture name or a redacted address.

## Live mailbox fixtures

| Fixture name | Provider/type | Address placeholder | State on 2026-10-28 | Cases | Required invariants |
|---|---|---|---|---|---|
| **Google fixture mailbox** | Gmail or Google Workspace | `<GOOGLE_FIXTURE_MAILBOX>` | Ready: use the existing owner-provisioned Google QA mailbox; address intentionally omitted here | TC-M6-01, TC-M6-03, TC-M6-08, TC-M6-09 | Google OAuth test-user access until item 134 is complete; existing app-password access is available only to prepare the pre-M6 migration fixture; inbox, Drafts, Sent and self-send available; no customer data |
| **Microsoft personal fixture** | Outlook.com personal account | `<MICROSOFT_PERSONAL_FIXTURE>` | **Waiting on Michael:** approve and create a Genkei-owned Outlook.com mailbox, then provision it to Lucius without putting its address or credentials in git | TC-M6-04–TC-M6-07, TC-M6-09 | Personal-account consent allowed; IMAP and SMTP OAuth access enabled; inbox, Drafts, Sent Items and self-send available; consent may be revoked and restored during QA |
| **Microsoft work fixture** | Microsoft 365 developer-tenant mailbox | `<MICROSOFT_WORK_FIXTURE>` | **Waiting on Michael:** approve a Genkei-owned Microsoft 365 developer-program tenant/mailbox, then provision it to Lucius without putting its address, tenant identifier or credentials in git | Item 31 live dispatch, TC-M6-10, TC-M6-11 | Commercial work/school account; admin can disable/enable SMTP AUTH and user consent; IMAP available; publisher/admin-consent behavior observable; renewable free developer tenant if Microsoft eligibility permits |

The Microsoft work fixture supplies both normal and protocol-disabled states; do not create a third mailbox merely for SMTP-disabled coverage. Toggle the test mailbox's setting before the relevant dispatch and restore it afterward. Do not use production/customer tenants.

## Local compatibility fixtures

| Fixture name | Value recorded in docs | How it is prepared | Cases | Invariants |
|---|---|---|---|---|
| **Other IMAP placeholder** | `other-imap@example.com` | UI-only input; no connection is attempted | TC-M6-02 | Reserved `example.com` data only; exercises hint/disclosure state without DNS or credentials |

## Deterministic messages and drafts

Use a unique run ID `M6-YYYYMMDD-HHMM` in every live subject so reruns cannot collide.

- Draft subject: `[Sentwise M6 QA draft] <RUNID>`
- Self-send subject: `[Sentwise M6 QA sent] <RUNID>`
- Local recovery draft subject: `[Sentwise M6 QA keep] <RUNID>`
- Body: `Sentwise M6 QA fixture. No reply required. Run <RUNID>.`

Each live mailbox begins a case with zero messages containing that run ID. After TC-M6-04, exactly one draft and exactly one sent message with the run ID exist. Teardown deletes the run's test messages and drafts, restores revoked consent only when the next case needs it, and restores any Microsoft work-mailbox protocol setting changed for a failure test.

## Provisioning and readiness

There is no committed seed script because these are external OAuth mailboxes, not application database rows. `homelab-it` or the owner provisions the accounts; Lucius consumes their secret references through the test environment. Before dispatch, the run brief records only these readiness flags:

- `GOOGLE_FIXTURE_READY=yes`
- `MICROSOFT_PERSONAL_FIXTURE_READY=yes` — blocked until Michael approves/creates it
- `MICROSOFT_WORK_FIXTURE_READY=yes` — blocked until Michael approves/creates it

A value of `no` blocks only the cases naming that fixture; it does not justify substituting a personal or customer mailbox. No secret value or real mailbox address is printed while checking readiness.
