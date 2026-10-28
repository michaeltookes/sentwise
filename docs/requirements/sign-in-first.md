# Sign-in first: Google at launch, app password behind "Other ways to connect", Microsoft next

Slug: `sign-in-first`. Source: owner decision 2026-10-28 ("Sentwise connects with sign-in, not app passwords", genkei-ops `docs/decisions.md`). Status: draft by business-analyst; design in `docs/architecture/sign-in-first.md` (solution-architect, 2026-10-28), which also edited the stories below (marked "Architect:").

## 1. Problem

Who: a first-run user (Marcus, the AE persona; Priya for inbox replies) connecting a mailbox. Today the connect screen (`OnboardingView.swift` account step, `EmailAccountSettingsView.swift`) offers "Continue with Google" next to an app-password form (email, app password, Test Connection, guidance, "Advanced (IMAP server)"). The app password is a poor first-run experience and the owner does not want to present it to prospects. How we know: owner statement 2026-10-28; item 110/121 already cut first-run friction for Gmail.

Constraints that shape the order: the Google client is in the Testing stage (100 users, tokens expire after 7 days), so the public launch needs the client published and CASA-verified (items 134, genkei-ops 31). Microsoft ended password IMAP login for personal accounts, so Outlook.com / Hotmail users cannot connect today at all. Deleting the app-password path would drop iCloud, Yahoo, AOL, AT&T and custom hosts (host suggestion and credential guidance, `EmailProviderKind`, item 41/43 work, shipped) which have no OAuth path we can use.

## 2. Goal and non-goals

Goals
- G1. At public launch a Gmail / Google Workspace user connects only through "Sign in with Google"; no app-password field is visible by default.
- G2. iCloud, Yahoo, AOL, AT&T and custom-host users can still connect, behind an advanced "Other ways to connect" disclosure.
- G3. Microsoft sign-in (Outlook.com, Hotmail, Microsoft 365) ships as the second provider in the release after launch (item 31).

Non-goals
- Removing or rewriting the IMAP engine, `SentwiseMail`, app-password storage, host suggestion or credential guidance. They stay as is.
- Migrating or disconnecting existing app-password accounts.
- OAuth for iCloud, Yahoo, AOL, AT&T (none usable).
- Microsoft Graph REST mail, Teams, Calendar (see section 8 and item 31 history).

## 3. Users and roles

- New user (no account connected). Existing user with an app-password account (must keep working and stay manageable). Gmail / Workspace user. Non-Google IMAP user (iCloud, Yahoo, AOL, AT&T, custom host). Microsoft user (personal or work/school). Owner: publishes the consent screen, submits, pays the CASA lab (not an app role).

## 4. Part A: hide the app password (backlog item 135)

Gate: item 135 must not ship to the public channel until item 134 is done (which itself needs landing-page item 16 and sentwise item 137) (client In production AND CASA Letter of Validation accepted by Google, verification approved). Build may land earlier behind a flag; the flag defaults to the old UI until the gate is cleared. The flip is an owner-approved step, not automatic.

### Stories
- **US-sign-in-first-1** As a new Gmail or Workspace user, I want the connect screen to show only "Sign in with Google", so that I never see or need an app password.
- **US-sign-in-first-2** As an iCloud, Yahoo, AOL, AT&T or custom-host user, I want an "Other ways to connect" option, so that I can still connect with an app password.
- **US-sign-in-first-3** As a user who already connected with an app password, I want my account to keep working and stay editable, so that the change does not lock me out.
- **US-sign-in-first-4** As the owner, I want the UI change to ship only after Google publishing and CASA are complete, so that no prospect hits the 100-user cap or the unverified-app warning.

### Acceptance criteria
US-sign-in-first-1
- Given the gate flag is on and no account is connected, When the account step of onboarding opens, Then an email field, "Continue with Google" and a collapsed control labeled "Other ways to connect" (accessibility identifier `otherWaysToConnect`) are visible, and the SecureField labeled "App password" is not in the view hierarchy. Architect: the email field sits outside the disclosure and is shared with the expanded form; its value is the Google `login_hint` and the input to provider detection. "Gate flag on" means `BuildConfiguration.signInFirst` is true (build setting `SENTWISE_SIGN_IN_FIRST=YES`) and `isGoogleSignInAvailable` is true. Tasks T135-1 to T135-4.
- Given the same state in Settings > Account (`EmailAccountSettingsView`), Then the same holds.
- Given the user types a `@gmail.com` or Workspace-MX-detected address, When the screen updates, Then no app-password field appears and Google sign-in stays the only primary action.
- Given the Google sign-in fails (user cancels, network down, consent denied), When the error shows, Then the message names the cause and offers "Try again"; the app-password form is still not shown by default and "Other ways to connect" remains reachable.
- Given the subtitle text, Then it no longer says "Other providers connect with an app password"; copy comes from the ui-designer's UX review.

US-sign-in-first-2
- Given the disclosure is collapsed, When the user activates "Other ways to connect" (click, or Space/Return via keyboard, announced by VoiceOver as expandable), Then it expands to show app password, Test Connection, provider guidance and the existing "Advanced (IMAP server)" disclosure, unchanged in behavior, using the email already typed in the shared field.
- Given the user types `name@icloud.com`, When they expand the disclosure, Then the IMAP host is suggested as today and the iCloud app-password guidance shows (existing tests for `EmailProviderKind` stay green).
- Given a `@yahoo.com`, `@aol.com`, `@att.net` or custom-domain address (not Workspace-detected), When the user has typed it on the sign-in screen, Then the screen points to "Other ways to connect" (inline hint, no auto-expand) so they are not stuck. Task T135-5.
- Architect (A9): Given an `@outlook.com`, `@hotmail.com`, `@live.com`, `@msn.com` address or a Microsoft 365 MX domain in a build without Microsoft sign-in, When typed, Then an inline note says Microsoft no longer accepts app passwords for these accounts and Microsoft sign-in is coming; "Other ways to connect" stays reachable; the copy does not claim Outlook support.
- Given the user enters a wrong app password in the expanded form, When they press Test Connection, Then the existing error appears and nothing is stored.
- Given a user types a Gmail address inside the expanded form and a valid app password, Then the connection still succeeds (the engine is unchanged); no feature removal.

US-sign-in-first-3
- Given an account connected by app password before the update, When the app launches the new build, Then the account remains connected, mail syncs, and Settings shows it with its edit and disconnect controls.
- Given that account, When the user opens Settings > Account to change the password, Then the disclosure is expanded for that account (account has no `authProvider` and a stored app password) and the app-password field is visible without a click. Task T135-6.
- Given the user disconnects the last app-password account, When the connect screen returns, Then the default (hidden) state applies again.

US-sign-in-first-4
- Given item 134 is not marked done in `docs/backlog.md`, When a release candidate is cut, Then the repository variable `SENTWISE_SIGN_IN_FIRST` is unset, the built Info.plist has an empty `SentwiseSignInFirst`, and the build shows the current UI (checked in the release checklist, item 74/131 evidence). Tasks T135-7, T135-8.
- Given the flag is on in a production build, When the Google consent screen opens, Then it shows no "Google hasn't verified this app" interstitial and no 100-user cap error (verified by a Lucius live check with an account not on the test-user list).
- Given the flag is on, Then the Prowl hunt-mode behavior (the Google option hidden unless the fake is active) is unchanged: with Google unavailable, the app-password form is shown, because hiding it would leave no way to connect.

### Constraints
- The "Google unavailable" path (`isGoogleSignInAvailable` false: no client id in the build, Prowl hunt mode, kill-switch) must show the app-password form directly. The hide applies only when Google sign-in is available.
- Accessibility: the disclosure is keyboard operable, has a clear accessibility label and state; Dynamic Type and light/dark per the design lane.
- No copy on this screen may promise a path we hide ("or use an app password"), and no copy may name Prowl.

## 5. Part B: gating items

- Item 134 (new): Google OAuth consent screen published, restricted-scope verification approved, CASA Tier 2 Letter of Validation accepted, annual renewal on the calendar. Steps are in `docs/gmail-oauth.md` sections 4-5. Vendor-ops prepares the submission (genkei-ops backlog 31); the owner publishes, submits and pays the lab.
  - **US-sign-in-first-5** As the owner, I want the Google client published and CASA-verified, so that any Gmail user can sign in without the 100-user cap or the 7-day token expiry.
  - Given the client is In production and verification is approved, When a Google account that is not a listed test user signs in on a production build, Then consent completes with no unverified-app interstitial.
  - Given a refresh token issued 8 or more days earlier, When the app refreshes it, Then it succeeds (no 7-day Testing expiry); on `invalid_grant` the app shows "Sign in with Google again" instead of failing silently.
  - Given verification is rejected or pending, When the gate is checked, Then item 135 stays gated and the owner gets an inbox line with Google's reason.
  - Evidence: the Verification Center status and the Letter of Validation reference recorded (no secrets) in `docs/launch-checklist.md`.
- Further gates for 134 (verification cannot be submitted without them):
  - landing-page repo item 16 (`sentwise-landing-page` `docs/backlog.md`, branch `req/sign-in-first`): the /privacy page carries the Google "Limited Use" disclosure and local-first facts. Acceptance text is in that item. Gates genkei-ops backlog 31.
  - sentwise item 137: 120x120 consent-screen logo (ui-designer designs, owner approves).
  - Dependency chain: 16 + 137 -> genkei-ops 31 (vendor-ops submission) -> 134 -> 135.
- No Sentwise backlog item for item 41 (IMAP host suggestion) or 43 (credential guidance) is open: both shipped (see `EmailProviderKind.swift`); this brief only depends on them.

## 6. Part C: Microsoft sign-in (backlog item 31, second provider, release after launch)

Item 31 today reads "Graph API + OAuth provider". Per the owner decision it becomes Microsoft sign-in over IMAP/SMTP with XOAUTH2, the same shape as the Gmail path (`GoogleMailAuthService`, `GoogleOAuth.swift`, `XOAuth2` in `SentwiseMail`, loopback redirect in `OAuthRedirect.swift`). Graph REST is not in scope unless the architect shows XOAUTH2 cannot meet the stories.

### Stories
- **US-sign-in-first-6** As an Outlook.com or Hotmail user, I want "Sign in with Microsoft", so that I can connect even though password IMAP login no longer works for my account.
- **US-sign-in-first-7** As a Microsoft 365 work or school user, I want to sign in with my organization account, so that Sentwise can use my work mailbox, or tell me clearly when my IT admin must approve it.
- **US-sign-in-first-8** As a connected Microsoft user, I want to stay signed in without repeated prompts, and to be told plainly when I must sign in again.
- **US-sign-in-first-9** As a Microsoft user, I want drafting, approval and sending to behave exactly as for Gmail, so that I lose nothing by not using Gmail.
- **US-sign-in-first-10** As a user, I want the consent copy to say what Sentwise reads and where it goes, so that I can decide to connect.

### Acceptance criteria
US-sign-in-first-6
- Given a personal `@outlook.com` or `@hotmail.com` account and a build with the Microsoft client configured, When the user chooses "Sign in with Microsoft" and consents in the browser, Then the app shows "Connected as <address> with Microsoft", the inbox and Sent folder are fetched over IMAP with XOAUTH2, and no password was entered in Sentwise. Architect: the address comes from the ID token (`email`, else `preferred_username`), the token request carries no `client_secret`, and connect verification runs IMAP LIST/SELECT plus an SMTP AUTH-only probe before the account is adopted (architecture 6.1).
- Given the user closes the browser or denies consent, When control returns, Then the app shows "Microsoft sign-in was cancelled" (or the denial reason) with "Try again", and nothing is stored.
- Given the loopback redirect receives a `state` that does not match, Then the sign-in is rejected and no tokens are stored.
- Given the connect screen, Then "Sign in with Microsoft" appears alongside Google, ordered by the typed address's domain when recognized (outlook.com, hotmail.com, live.com, msn.com, or an MX pointing to Microsoft 365), otherwise both are offered. Microsoft 365 MX = an MX host ending in `.mail.protection.outlook.com`.
- Architect: Given the Microsoft client ID is empty in the build or Prowl hunt mode is on without the fake, Then "Sign in with Microsoft" is not shown and no Microsoft-specific copy appears.
- Delivery note (architect): item 31 is several builder branches, not one; build order and tasks T31-1 to T31-10 are in architecture section 11. T31-1 (provider-neutral refactor, Google tests unchanged and green) lands first.

US-sign-in-first-7
- Given a work address on a tenant that allows user consent, When the user signs in, Then connection succeeds as in story 6.
- Given a tenant that requires admin consent, When the user signs in, Then the app shows "Your organization requires an administrator to approve Sentwise" with a "Copy a note for your IT admin" action, not a raw AADSTS code (the raw code is logged field-only).
- Given a tenant that has disabled IMAP or SMTP AUTH for the mailbox, When connect verification runs (IMAP AUTHENTICATE with a token minted under 60 s earlier, then the SMTP AUTH-only probe; SMTP reply 5.7.139 or 5.7.3), Then the message names the protocol that is off, offers the admin note (which includes the `Set-CASMailbox` line), the tokens are deleted and the account is not adopted. Tasks T31-3, T31-7.
- Given scope/consent copy, Then it states plainly that admin approval may be needed for work accounts (honest requires-IT-approval statement, same lesson as the parked BYO-OAuth path).

US-sign-in-first-8
- Given a connected Microsoft account, When the access token is within its expiry margin, Then the app refreshes it silently before IMAP/SMTP use and the user sees no prompt.
- Given the refresh token is revoked, expired or the password changed (`invalid_grant`), When the app next syncs, Then it shows "Sign in with Microsoft again" once, stops retrying, and keeps drafts already generated.
- Given two simultaneous operations need a token, Then only one refresh request is made (mirrors the Google superseded-refresh tests).
- Architect: Given a refresh succeeds, Then the new refresh token returned by Microsoft replaces the stored one (rotation), verified by a unit test.
- Architect: Given the Mac is offline or Microsoft returns 429/5xx/`temporarily_unavailable`, Then no "sign in again" prompt appears; the app backs off (30 s, 2 min, 10 min) and retries on the next sync.
- Given the user chooses Disconnect, Then the Keychain item `microsoft.oauthToken.<address>` is deleted, the app shows the disconnected state and a link to remove Sentwise's access in the Microsoft account (Microsoft has no revocation endpoint).

US-sign-in-first-9
- Given a connected Microsoft account, When Sentwise learns voice, drafts a reply, the user approves and sends, Then the draft is appended to Drafts (IMAP APPEND, existing code), the sent message appears in Sent Items (saved server-side by Microsoft on SMTP submission; verified by the live test, T31-9), with the same approval gating as Gmail (nothing is sent without approval). SMTP uses port 587 with STARTTLS (`smtp-mail.outlook.com` personal, `smtp.office365.com` work); the client refuses to authenticate if STARTTLS is not offered. Task T31-6.
- Given the send fails (SMTP rejected, token expired mid-send), Then the draft is kept, an error names the cause, and nothing is sent twice.
- Given a Microsoft account, Then Sent, Drafts, Junk, Trash and Archive come from the IMAP SPECIAL-USE attributes when present, falling back to `MailboxNaming.microsoft` (Sent Items, Drafts, Junk Email, Deleted Items, Archive), so localized mailboxes work; other providers keep today's static names. Task T31-8.

US-sign-in-first-10
- Given the Microsoft connect screen, Then it shows consent copy covering: what is requested (read, draft and send mail on the user's behalf), that mail and tokens stay on the Mac and tokens live in the Keychain this-device-only, and that Sentwise servers never receive mail credentials; copy reviewed by the owner before release. Constraint: no copy before the item 31 release says Outlook is supported, and none says Sentwise does not read mail (it reads it on the Mac). Task T31-10.
- Given the Microsoft privacy facts, Then the privacy policy page on sentwise.ai names Microsoft data use before the feature is enabled in a public build.

### Constraints
- Tier gating and billing: no change; Microsoft is available on every tier that has mail connection today (confirm in `docs/tier-matrix.md`).
- Prowl lane: Microsoft sign-in is off in Prowl hunt mode unless a fake is active, matching Google.
- Release order: ships after the launch release; the Part A hide does not wait for it, but the Microsoft user group has no connect path at launch other than "Other ways to connect" (which cannot work for personal Microsoft accounts). The launch copy must not claim Outlook support.

## 7. Data and privacy notes

- Leaves the device: only the OAuth exchange with Google or Microsoft through the user's browser and the loopback redirect. Mail content, tokens and passwords never go to a Sentwise server; the managed proxy never receives mail credentials (unchanged).
- Stored: refresh and access tokens in the Keychain, this-device-only, per provider; for app-password accounts the existing Keychain item.
- Google: Limited Use disclosure and scope justification for `https://mail.google.com/` are CASA/verification requirements (item 134).
- Microsoft: needs equivalent privacy-policy language and, for work accounts, tenant-admin consent disclosure; Microsoft publisher verification is expected to reduce unverified-publisher warnings (architect to confirm).
- Consent-screen copy per provider is owner-reviewed before release.

## 8. Open questions

Owner (assumption taken)
1. Is Microsoft sign-in allowed to slip past the release after launch if Microsoft publisher verification or tenant consent proves slow? Assumption: yes; ship personal accounts first if work accounts are blocked.
2. Who owns the Azure/Entra registration: a Genkei Labs LLC tenant? Assumption: the owner creates it; vendor-ops prepares the steps (new vendor not yet in the vendor-config roster).
3. Does the owner accept CASA cost (about $500-1,000 per year, doc estimate) and a 2-6+ week review clock before public launch? Assumption: yes (decision 2026-10-28 names it).
4. Should existing app-password users see any nudge to switch to Google sign-in? Assumption: no nudge in this release.

For the solution-architect (item 31 design). Answered in `docs/architecture/sign-in-first.md` section 10; owner questions raised there: Entra tenant and partner enrolment, personal-first release, test mailboxes.
- A1. Azure/Entra app registration: multi-tenant vs personal-only vs "personal + organizational" (`common` vs `consumers` vs `organizations` authority); public client for a native macOS app with loopback redirect (`http://127.0.0.1:<port>`) or custom scheme; PKCE; whether a client secret is ever needed; publisher domain and publisher verification (MPN) requirements.
- A2. Scopes: `https://outlook.office.com/IMAP.AccessAsUser.All`, `https://outlook.office.com/SMTP.Send`, `offline_access`, `openid`, `email`; confirm the minimal set, whether IMAP and SMTP scopes can be requested in one token (different resources), and Graph `Mail.ReadWrite`/`Mail.Send` as a fallback only if XOAUTH2 fails.
- A3. Token refresh: lifetime of refresh tokens (90 days sliding for public clients), rotation behavior, conditional-access and password-change revocation, error codes mapped to the "sign in again" UX; reuse of the Google single-flight refresh actor.
- A4. Account types in scope: personal (Outlook.com, Hotmail, Live, MSN), Microsoft 365 work/school, Exchange Online shared mailboxes, GCC/sovereign clouds, on-prem Exchange (assumption: personal and M365 commercial in scope; the rest out).
- A5. Tenant admin consent and IMAP/SMTP AUTH being disabled by default in some tenants (SMTP AUTH disabled tenant-wide): detection, message, and whether IMAP XOAUTH2 requires per-mailbox enablement.
- A6. IMAP/SMTP endpoints (`outlook.office365.com:993`, `smtp.office365.com:587` STARTTLS) versus the existing `SentwiseMail` transport (SMTP submission with STARTTLS and XOAUTH2 may be a new capability); Sent-folder and Drafts discovery.
- A7. Generalizing `GoogleMailAuthService`/`GoogleOAuth`/`MailConnectMethod`/`EmailProviderKind` into a provider-neutral OAuth layer without regressing Google; Keychain account naming for multiple providers; the multi-account model.
- A8. Whether any CASA-like review applies to Microsoft (assumption: no, but publisher verification and possibly app-certification for tenant admins).
- A9. Backwards-compatibility of the hide flag and how "Other ways to connect" behaves for `@outlook.com` addresses until Microsoft ships (explain why no app-password path works).

## 9. Out of scope
Microsoft Teams, Microsoft Calendar, Graph-based calendar; Google Workspace admin allowlisting guidance changes; removing the IMAP/app-password code; Yahoo/AOL/iCloud OAuth; SSO/SAML; Apple Mail account import.

## 10. Traceability

| Story | Backlog item | Test case |
|---|---|---|
| US-sign-in-first-1 to 4 | 135 | to be added by project-planner |
| US-sign-in-first-5 | 134, 137, landing-page 16 (and genkei-ops 31 for vendor-ops prep) | to be added by project-planner |
| US-sign-in-first-6 to 10 | 31 (build); 136 (Azure registration, owner/vendor-ops) | to be added by project-planner |

## UX review

Reviewed against the current `OnboardingAccountStep`, `GoogleOrAppPasswordConnect`, `GoogleSignInButtonBlock`, and `EmailAccountSettingsView`. The existing screen has a good native base, but moving the email field outside the app-password form changes the flow: the address must become the first control, provider choice the second, and progress or recovery must stay in place instead of replacing the controls.

### Recommended flow and hierarchy

1. **First run, Google-only launch (US-sign-in-first-1, T135-2 to T135-5):** show the heading, one-line explanation, email field, full-width primary `Continue with Google` button, then the collapsed `Other ways to connect` disclosure. Do not show an app-password field, an `or` divider, or an Outlook claim.
2. **Provider-two release (US-sign-in-first-6, T31-4, T31-5):** keep the same screen. Show `Continue with Google` and `Continue with Microsoft` as equal native bordered buttons. Put the detected provider first, but never remove the other available provider. Detection may recommend, not decide. `Other ways to connect` remains a disclosure below both buttons, not a third provider tile.
3. **Other IMAP (US-sign-in-first-2, T135-3, T135-5):** activating `Other ways to connect` reveals the existing app-password, Test Connection, guidance, and Advanced controls. Keep the shared email field above it. This is an exit from the preferred flow, so it is discoverable but visually secondary and never opens automatically.
4. **Browser handoff (US-sign-in-first-1, US-sign-in-first-6):** leave the connect screen open, disable only provider actions that would start a second authorization, show progress directly below the chosen button, and provide `Cancel`. A return from the browser resumes in the same place.
5. **Success (US-sign-in-first-1, US-sign-in-first-6):** replace the chooser with the existing connected confirmation, announce it, and enable onboarding `Continue`. Settings retains Disconnect and Add another account. Do not advance onboarding automatically because the confirmation is useful and the next step is a separate Sentwise account sign-in.
6. **Exit and recovery:** Back preserves a completed mailbox connection. Cancel stops only the active browser attempt and keeps the typed address. Closing onboarding preserves a completed connection but does not mark onboarding complete. Disconnect returns to the collapsed first-run state when no app-password account is being edited.

### Final screen copy

These strings are final for builder use. They use `Continue` for first connection and reserve `Sign in again` for recovery.

**Setup heading and subtitles (US-sign-in-first-1, T135-4)**
- Heading: `Connect your inbox`
- Sign-in-first, Google only: `Enter your email, then continue with Google. Your sign-in is saved securely on this Mac.`
- Google and Microsoft available: `Enter your email, then choose Google or Microsoft. Your sign-in is saved securely on this Mac.`
- OAuth unavailable fallback: `Connect with your email address and an app password.`
- Shared email field label: `Email address`
- Google button: `Continue with Google`
- Microsoft button: `Continue with Microsoft`
- Disclosure: `Other ways to connect`
- Disclosure hint for VoiceOver: collapsed `Connect another email provider with an app password`; expanded `Hide app-password connection options`

**Provider hints (US-sign-in-first-2, T135-5)**
- iCloud: `Use Other ways to connect for iCloud Mail.`
- Yahoo: `Use Other ways to connect for Yahoo Mail.`
- AOL: `Use Other ways to connect for AOL Mail.`
- AT&T: `Use Other ways to connect for AT&T Mail.`
- Unknown or custom domain: `If your provider is not listed, use Other ways to connect.`
- Microsoft before item 31 ships: `Microsoft no longer accepts app passwords for Outlook.com and Hotmail. Microsoft sign-in is coming in a future update.`
- Do not show a hint for Gmail or a detected Google Workspace domain.

**Google context and consent summary (US-sign-in-first-1, T135-4)**
- Idle helper: `For Gmail and Google Workspace. Sentwise reads your mailbox on this Mac to find messages and sends only the content needed to draft a reply through its private drafting service.`
- This replaces the current long helper and removes the inaccurate absolute impression created by `nothing is stored on our servers` beside a drafting-service statement.

**Microsoft consent block (US-sign-in-first-7, US-sign-in-first-10, T31-10)**
- Heading: `Before you continue`
- Body: `Sentwise will ask Microsoft for permission to read your mail, save drafts, and send messages you approve. Mail is read on this Mac. Your sign-in tokens are stored in this Mac's Keychain and are never sent to Sentwise servers.`
- Work-account note: `Your IT administrator may need to approve Sentwise for a work or school account.`
- The block appears before the Microsoft button opens the browser. It is supporting text, not a confirmation sheet. Do not say Sentwise never reads mail.

### State copy and behavior

| State | User sees | Action and acceptance note |
|---|---|---|
| Empty, first run | Subtitle, empty `Email address`, available provider button or buttons, collapsed `Other ways to connect` | Focus starts in Email address. Provider buttons remain usable without an address because the provider can collect one. (US-1, T135-2) |
| Detecting provider | `Checking your email provider…` below the email field | Small progress indicator, no modal, no focus change, and provider buttons remain enabled. Remove it when detection finishes. (US-1, T135-5) |
| Opening browser | `Opening Google in your browser…` or `Opening Microsoft in your browser…` | Progress is announced once. If opening fails, use the network-error state. (US-1, US-6, T31-5) |
| Waiting for callback | `Finish signing in with Google in your browser.` or `Finish signing in with Microsoft in your browser.` | Show `Cancel`. The chosen button is disabled and retains its label. Escape activates Cancel when focus is within this flow. (US-1, US-6, T31-5) |
| Exchanging code | `Sign-in complete. Connecting your mailbox…` | Keep progress visible. No Cancel after the provider has returned a code. (US-1, US-6, T31-3) |
| Verifying Microsoft mail access | `Sign-in complete. Checking mail and sending access…` | Covers IMAP and SMTP probes without exposing protocol jargon unless one fails. (US-6, US-7, T31-7) |
| Success | `Connected as <address> with Google` or `Connected as <address> with Microsoft` | Checkmark, VoiceOver announcement, and onboarding Continue enabled. (US-1, US-6, T31-5) |
| Cancelled or browser closed | `Google sign-in was cancelled.` or `Microsoft sign-in was cancelled.` | `Try Again`; preserve the email and disclosure state; store nothing. Treat the 300-second timeout as cancellation. (US-1, US-6, T31-3) |
| Consent denied or required scope missing | `<Provider> did not grant mail access. Try again and allow mail access.` | `Try Again`; do not call this cancellation when the provider returned a scope error. (US-1, US-6, T31-3) |
| Network unavailable before connection | `You're offline. Connect to the internet, then try again.` | `Try Again`; preserve all input; do not offer app password as an automatic fallback. (US-1, US-6, T31-3) |
| Provider temporarily unavailable | `<Provider> is not responding. Sentwise will try again.` | No reauthentication prompt. Add `Try Now` after backoff begins. (US-8, T31-3) |
| Callback could not be verified | `Sign-in could not be verified. Try again.` | `Try Again`; store nothing. Do not expose `state` or raw provider codes. (US-6, T31-3) |
| Admin approval required | `Your organization requires an administrator to approve Sentwise.` | Primary `Copy a Note for Your IT Admin`; secondary `Choose Another Account`. Announce copy success as `Note copied.` (US-7, T31-3, T136-3) |
| IMAP disabled | `IMAP access is off for this mailbox.` | `Copy a Note for Your IT Admin`; delete new tokens and do not add the account. (US-7, T31-7) |
| SMTP AUTH disabled | `Sending is off for this mailbox.` | Supporting text: `Your administrator needs to enable SMTP AUTH before Sentwise can connect.` Same actions and cleanup as IMAP. (US-7, T31-7) |
| Token expired or revoked on next launch | `Sign in with Google again to keep <address> connected.` or Microsoft equivalent | One persistent, nonmodal banner in Settings and account row action `Sign in with <Provider> Again`. Keep local drafts. Do not repeat alerts. (US-5, US-8, T31-3) |
| Account already linked and active | `This mailbox is already connected.` | Show `View Account`; do not replace tokens or add a duplicate. In onboarding, show the connected confirmation and enable Continue. (US-3, US-6, T135-6) |
| Account already linked but saved in background | `<address> is already in your mailboxes.` | Show `Use This Account`; return to the account list after selection. (US-3, T135-6) |
| Existing app-password account | Existing connected state; when edited, expanded app-password controls | Do not show a migration nudge. Preserve the password and focus. (US-3, T135-6) |
| Partial failure after OAuth | Provider-specific protocol message above; no connected badge | Never leave a half-added account. Keep typed email, delete the new grant, and retain any local drafts from an older connection. (US-7, T31-7) |

All inline errors use sentence case, sit directly after the progress or provider block, and carry a recovery action. `Try Again` is title case on buttons. Do not use raw OAuth, AADSTS, IMAP, or SMTP terms except the two administrator-facing protocol messages above.

### Accessibility and macOS conventions

- **Focus order (US-1, US-6, T135-3, T31-5):** Email address, recommended provider, other provider when available, Other ways to connect, then its revealed fields and Test Connection, Back, Continue. Reordering providers must not move focus while the user is typing.
- **Keyboard path:** Tab and Shift-Tab traverse all controls; Space or Return toggles the disclosure; Return activates the focused provider button; Escape cancels only an active browser wait. The onboarding default action remains Continue only after a mailbox connects, so pressing Return in the email field must not skip the step.
- **VoiceOver:** provider buttons read their visible labels with the hint `Opens your browser to connect this mailbox`. The disclosure exposes button and expanded or collapsed traits. Provider hints and state changes are one polite live region. Errors receive focus only after a user action, not after background detection.
- **Progress:** every indeterminate indicator has the adjacent state sentence as its accessibility label. Do not announce each animation cycle. Respect Reduce Motion when the connected badge replaces the chooser.
- **Status item names (US-5, US-8, T31-3):** normal `Sentwise`; onboarding incomplete `Sentwise, setup required`; expired or revoked mailbox grant `Sentwise, mailbox sign-in required`; ready drafts continue to use the existing draft-count name. The status item menu includes `Finish Setup…` or `Sign In to Mailbox…` before draft actions when those states apply.
- **Text and contrast:** retain semantic system colors and fonts. Do not rely on green or red alone; success has a checkmark and text, errors have text. The 460-point onboarding window must scroll at the largest supported macOS text size without hiding recovery actions.
- **Privacy:** typed addresses and account names are private VoiceOver content, not help tags or status-item labels. No token, tenant ID, raw provider error, or copied admin note appears in accessibility values.

### Concrete story changes for the BA to fold

1. **Split US-sign-in-first-1 / T135-4:** add a copy acceptance criterion for all three subtitle states and the Google helper above. Replace `Sign in with Google` with `Continue with Google` for first connection; keep `Sign in with Google again` for reauthentication.
2. **Add to US-sign-in-first-1 / T135-2, T135-3:** Given first-run setup, When the screen opens, Then focus is in Email address and the keyboard order follows the order specified above; Given an authorization is waiting, When the user presses Escape or activates Cancel, Then only that attempt ends and the typed email and disclosure state remain.
3. **Add to US-sign-in-first-2 / T135-5:** Given provider detection is pending, When MX lookup runs, Then the UI says `Checking your email provider…`, keeps provider actions enabled, and never moves focus; Given a non-OAuth provider is detected, Then the exact provider hint above appears and Other ways to connect does not expand automatically.
4. **Add to US-sign-in-first-3 / T135-6:** Given the typed address is already connected, When connection is attempted, Then no duplicate or token replacement is created and the screen offers `View Account` or `Use This Account` as appropriate.
5. **Add to US-sign-in-first-5 / T31-3:** Given Google returns `invalid_grant` on launch, When the account needs attention, Then the user sees the one-time persistent reauthentication copy above, the status item is named `Sentwise, mailbox sign-in required`, and existing drafts remain available.
6. **Split US-sign-in-first-6 / T31-5 into provider choice and browser handoff:** provider choice owns ordering, recommendation, and both equal buttons; browser handoff owns opening, waiting, cancellation, callback verification, verification progress, and success. This keeps the screen work independently testable.
7. **Add to US-sign-in-first-7 / T31-3, T31-7:** distinguish cancellation, denied scope, admin approval, IMAP-disabled, SMTP-disabled, and partial verification using the exact copy and cleanup behavior above. A raw AADSTS response never reaches visible or accessibility text.
8. **Add to US-sign-in-first-8 / T31-3:** Given the Mac is offline or Microsoft is temporarily unavailable, Then no sign-in-again prompt appears; the current account and drafts remain, and the offline or retry copy above is shown once.
9. **Add to US-sign-in-first-10 / T31-10:** use the final Microsoft consent block above before browser handoff; require owner approval of that copy and a light, dark, keyboard, and VoiceOver check before enabling Microsoft publicly.
10. **Add to item 136 / T136-2, T136-3, T136-5:** Given the public Microsoft flow is enabled, Then the browser consent page shows the sentwise.ai publisher domain and verified publisher identity, and the return page names Sentwise and tells the user to return to the app. If the random-port redirect fails validation, the feature stays unavailable rather than exposing a broken button.
11. **Add view-state coverage to T135-8 and T31-5:** empty, detecting, opening browser, waiting, exchanging, verifying, success, cancelled, denied scope, offline, temporary provider failure, callback verification failure, expired token, already linked active, already linked background, admin approval, each protocol-disabled case, and partial cleanup. Cover onboarding and Settings where their exits differ.
