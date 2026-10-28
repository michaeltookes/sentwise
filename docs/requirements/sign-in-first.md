# Sign-in first: Google at launch, app password behind "Other ways to connect", Microsoft next

Slug: `sign-in-first`. Source: owner decision 2026-10-28 ("Sentwise connects with sign-in, not app passwords", genkei-ops `docs/decisions.md`). Status: draft by business-analyst; the solution-architect designs on this branch next (`docs/architecture/sign-in-first.md`).

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

Gate: item 135 must not ship to the public channel until item 134 is done (client In production AND CASA Letter of Validation accepted by Google, verification approved). Build may land earlier behind a flag; the flag defaults to the old UI until the gate is cleared. The flip is an owner-approved step, not automatic.

### Stories
- **US-sign-in-first-1** As a new Gmail or Workspace user, I want the connect screen to show only "Sign in with Google", so that I never see or need an app password.
- **US-sign-in-first-2** As an iCloud, Yahoo, AOL, AT&T or custom-host user, I want an "Other ways to connect" option, so that I can still connect with an app password.
- **US-sign-in-first-3** As a user who already connected with an app password, I want my account to keep working and stay editable, so that the change does not lock me out.
- **US-sign-in-first-4** As the owner, I want the UI change to ship only after Google publishing and CASA are complete, so that no prospect hits the 100-user cap or the unverified-app warning.

### Acceptance criteria
US-sign-in-first-1
- Given the gate flag is on and no account is connected, When the account step of onboarding opens, Then "Continue with Google" is visible, the SecureField labeled "App password" is not in the view hierarchy, and a collapsed control labeled "Other ways to connect" is visible.
- Given the same state in Settings > Account (`EmailAccountSettingsView`), Then the same holds.
- Given the user types a `@gmail.com` or Workspace-MX-detected address, When the screen updates, Then no app-password field appears and Google sign-in stays the only primary action.
- Given the Google sign-in fails (user cancels, network down, consent denied), When the error shows, Then the message names the cause and offers "Try again"; the app-password form is still not shown by default and "Other ways to connect" remains reachable.
- Given the subtitle text, Then it no longer says "Other providers connect with an app password"; copy comes from the ui-designer's UX review.

US-sign-in-first-2
- Given the disclosure is collapsed, When the user activates "Other ways to connect" (click, or Space/Return via keyboard, announced by VoiceOver as expandable), Then it expands to show email, app password, Test Connection, provider guidance and the existing "Advanced (IMAP server)" disclosure, unchanged in behavior.
- Given the user types `name@icloud.com`, When they expand the disclosure, Then the IMAP host is suggested as today and the iCloud app-password guidance shows (existing tests for `EmailProviderKind` stay green).
- Given a `@yahoo.com`, `@aol.com`, `@att.net` or custom-domain address (not Workspace-detected), When the user has typed it on the sign-in screen, Then the screen points to "Other ways to connect" (inline hint, no auto-expand) so they are not stuck.
- Given the user enters a wrong app password in the expanded form, When they press Test Connection, Then the existing error appears and nothing is stored.
- Given a user types a Gmail address inside the expanded form and a valid app password, Then the connection still succeeds (the engine is unchanged); no feature removal.

US-sign-in-first-3
- Given an account connected by app password before the update, When the app launches the new build, Then the account remains connected, mail syncs, and Settings shows it with its edit and disconnect controls.
- Given that account, When the user opens Settings > Account to change the password, Then the app-password field is reachable without first finding the disclosure, or the disclosure is auto-expanded for that account.
- Given the user disconnects the last app-password account, When the connect screen returns, Then the default (hidden) state applies again.

US-sign-in-first-4
- Given items 134 is not marked done in `docs/backlog.md`, When a release candidate is cut, Then the gate flag is off and the build shows the current UI (checked in the release checklist, item 74/131 evidence).
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
- Given a personal `@outlook.com` or `@hotmail.com` account and a build with the Microsoft client configured, When the user chooses "Sign in with Microsoft" and consents in the browser, Then the app shows "Connected as <address> with Microsoft", the inbox and Sent folder are fetched over IMAP with XOAUTH2, and no password was entered in Sentwise.
- Given the user closes the browser or denies consent, When control returns, Then the app shows "Microsoft sign-in was cancelled" (or the denial reason) with "Try again", and nothing is stored.
- Given the loopback redirect receives a `state` that does not match, Then the sign-in is rejected and no tokens are stored.
- Given the connect screen, Then "Sign in with Microsoft" appears alongside Google, ordered by the typed address's domain when recognized (outlook.com, hotmail.com, live.com, msn.com, or an MX pointing to Microsoft 365), otherwise both are offered.

US-sign-in-first-7
- Given a work address on a tenant that allows user consent, When the user signs in, Then connection succeeds as in story 6.
- Given a tenant that requires admin consent, When the user signs in, Then the app shows "Your organization requires an administrator to approve Sentwise" with a "Copy a note for your IT admin" action, not a raw AADSTS code (the raw code is logged field-only).
- Given a tenant that has disabled IMAP or SMTP AUTH for the mailbox, When Test Connection fails with an authentication error after a valid token, Then the message says IMAP/SMTP access is off for this mailbox and points to the admin note.
- Given scope/consent copy, Then it states plainly that admin approval may be needed for work accounts (honest requires-IT-approval statement, same lesson as the parked BYO-OAuth path).

US-sign-in-first-8
- Given a connected Microsoft account, When the access token is within its expiry margin, Then the app refreshes it silently before IMAP/SMTP use and the user sees no prompt.
- Given the refresh token is revoked, expired or the password changed (`invalid_grant`), When the app next syncs, Then it shows "Sign in with Microsoft again" once, stops retrying, and keeps drafts already generated.
- Given two simultaneous operations need a token, Then only one refresh request is made (mirrors the Google superseded-refresh tests).
- Given the user chooses Disconnect, Then the Keychain tokens are deleted and the app shows the disconnected state.

US-sign-in-first-9
- Given a connected Microsoft account, When Sentwise learns voice, drafts a reply, the user approves and sends, Then the sent message appears in the account's Sent items, and the draft is appended to Drafts, with the same approval gating as Gmail (nothing is sent without approval).
- Given the send fails (SMTP rejected, token expired mid-send), Then the draft is kept, an error names the cause, and nothing is sent twice.
- Given a Microsoft account, Then Sent-mail folder discovery uses the folder's special-use attribute (not the English name) so localized mailboxes work.

US-sign-in-first-10
- Given the Microsoft connect screen, Then it shows consent copy covering: what is requested (read, draft and send mail on the user's behalf), that mail and tokens stay on the Mac and tokens live in the Keychain this-device-only, and that Sentwise servers never receive mail credentials; copy reviewed by the owner before release.
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

For the solution-architect (item 31 design)
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
| US-sign-in-first-5 | 134 (and genkei-ops 31 for vendor-ops prep) | to be added by project-planner |
| US-sign-in-first-6 to 10 | 31 (build); 136 (Azure registration, owner/vendor-ops) | to be added by project-planner |
