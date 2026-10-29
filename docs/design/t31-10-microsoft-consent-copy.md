# Microsoft consent copy (item 31, T31-10)

## Goal and the one job

Before "Continue with Microsoft" opens the browser, tell the person in four short sentences what Sentwise is about to ask Microsoft for, where their mail goes, where their sign-in lives, and how to take the access back. The block is supporting text under the button, not a confirmation sheet: it informs the decision without adding a step.

The same facts go on sentwise.ai/privacy as a Microsoft section (change list at the end), which must be live before the Microsoft flag is on in a public build (US-sign-in-first-10; architecture 5.3).

## Users and the moment they arrive

- A personal Outlook.com, Hotmail, Live or MSN user on the connect step of onboarding or in Settings > Email Account. App passwords no longer work for them, so this is their only way in. They want to know whether it is safe to click.
- A Microsoft 365 work or school user. Same moment, plus the chance their organization blocks the app until an administrator approves it.
- A returning user whose grant expired or was revoked, arriving from the status item ("Sentwise, mailbox sign-in required") or the Settings banner.

## Constraints on the claims

The copy claims only what the requested scopes grant (`IMAP.AccessAsUser.All`, `SMTP.Send`, `offline_access`, `openid`, `profile`, `email`):

| Scope | Plain words used |
|---|---|
| `IMAP.AccessAsUser.All` | read your mail, save drafts |
| `SMTP.Send` | send messages you approve |
| `offline_access` | keep this Mac signed in |
| `openid`, `profile`, `email` | not named in the block (Microsoft's own screen lists them); named in the privacy section |

It must not say mail never leaves the Mac or that Sentwise does not read mail: Sentwise reads mail on the Mac, and drafting sends the content needed for a draft to the Sentwise drafting service (architecture 5.3), and Learn My Voice or Re-learn My Voice sends up to 12 recent sent messages there too, worded as `AppState.privacyStatement` words it. It must not mention delete, contacts, calendar or files. No copy before the item 31 release says Outlook is supported. The drafting sentence reuses the wording the UX review set for the Google helper ("only the content needed to draft a reply"), so both providers say it the same way.

## Where the copy appears

1. **Chooser block**: under "Continue with Microsoft" in the `.ready` state (`MicrosoftSignInButtonBlock.consentBlock`), on the onboarding connect step and in Settings > Email Account.
2. **Admin approval**: `.consentRequired`, after Microsoft returns AADSTS65001/90094/90095 or `consent_required`.
3. **Protocol-disabled recovery**: `.protocolDisabled(.imap | .smtp)`, after the post-sign-in probe finds IMAP or SMTP AUTH switched off.
4. **Reauthentication**: `.reauthenticate(address:)` on a saved mailbox, plus the mail-error detail shown when a sync hits `invalid_grant`.

## Flows

Happy path: type address (optional) > read block > Continue with Microsoft > browser > consent on Microsoft's page > "Sign-in complete. Checking mail and sending access…" > "Connected as <address> with Microsoft".

Exits: Cancel during the browser wait; cancelled or denied in the browser; admin approval required (copy a note, choose another account); IMAP or SMTP AUTH off (copy a note); offline; Microsoft not responding; callback not verified; grant expired later (sign in again).

## Hierarchy

1. The button "Continue with Microsoft" (bordered prominent, the one accent).
2. "Before you continue" (caption, semibold).
3. What Microsoft will ask for (caption, secondary).
4. Where mail and the sign-in go (caption, secondary).
5. Work-account note, when shown (caption, secondary).
6. How to remove access (caption, secondary), last because it matters after the decision, not before it.

## Every state and its exact strings

Strings are in `Sentwise/Sentwise/Models/MicrosoftSignInState.swift` (`MicrosoftSignInCopy`) unless noted. New or changed in this branch are marked **new** or **changed**; the rest shipped in PR 136 and are restated so the whole surface is approved in one place.

| State | String |
|---|---|
| Ready, heading | `Before you continue` |
| Ready, scopes (**changed**) | `Microsoft will ask you to let Sentwise read your mail, save drafts, and send messages you approve, and to keep this Mac signed in.` |
| Ready, privacy (**new**) | `Mail is read on this Mac. Only the content needed to draft a reply, and up to 12 of your sent messages each time you learn your voice, goes to the Sentwise drafting service. Your sign-in is kept in this Mac's Keychain and is never sent to Sentwise servers.` |
| Ready, work note (**changed**) | `For a work or school account, your IT administrator may need to approve Sentwise first.` |
| Ready, revoke (**new**) | `You can remove Sentwise's access at any time in your Microsoft account.` |
| Button | `Continue with Microsoft` (hint `Opens your browser to connect this mailbox`) |
| Opening | `Opening Microsoft in your browser…` |
| Waiting | `Finish signing in with Microsoft in your browser.` + `Cancel` |
| Exchanging | `Sign-in complete. Connecting your mailbox…` |
| Checking | `Sign-in complete. Checking mail and sending access…` |
| Success | `Connected as <address> with Microsoft` |
| Cancelled | `Microsoft sign-in was cancelled.` |
| Scope missing | `Microsoft did not grant mail access. Try again and allow mail access.` |
| Offline | `You're offline. Connect to the internet, then try again.` |
| Not responding | `Microsoft is not responding. Sentwise will try again.` |
| Not verified | `Sign-in could not be verified. Try again.` |
| Timed out | `Microsoft sign-in timed out. Try again and finish in your browser.` |
| Wrong account on reauth | `Choose <address> on Microsoft's screen to keep this mailbox connected.` |
| Admin approval | `Your organization requires an administrator to approve Sentwise.` + `Copy a Note for Your IT Admin` + `Choose Another Account`; after copy `Note copied.` |
| IMAP off | `IMAP access is off for this mailbox. Your administrator needs to enable IMAP before Sentwise can connect.` + `Copy a Note for Your IT Admin` |
| SMTP AUTH off | `Sending is off for this mailbox. Your administrator needs to enable SMTP AUTH before Sentwise can connect.` + `Copy a Note for Your IT Admin` |
| Reauthenticate (saved mailbox) | `Sign in with Microsoft again to keep <address> connected.` + `Sign in with Microsoft Again` |
| Expired during sign-in | `Your Microsoft sign-in has expired. Sign in with Microsoft again.` |
| Expired on sync, mail-error detail (`MicrosoftOAuth.swift`, **changed**) | `Microsoft sign-in expired or was revoked. Sign in with Microsoft again in Settings → Email Account.` |
| Not configured build | `Sign in with Microsoft isn't available in this build. Use an app password instead.` |

The Google twin of the expired-on-sync detail (`GoogleMailAuthService.swift`) got the same punctuation change so the two read alike. The copied admin note (`MicrosoftAdminNote.text`) is unchanged; it is administrator-facing and already names the delegated permissions verbatim.

Empty, loading, partial and offline are covered by the rows above (empty address is allowed: Microsoft collects it). First-run is the Ready state.

## Accessibility

- The consent block is one VoiceOver element whose label is `MicrosoftSignInCopy.consentAccessibilityText`, the visible sentences in visible order ("Before you continue." first), so it reads as one paragraph rather than four fragments. Identifier `microsoftConsentBlock`.
- Focus order is unchanged: the block is static text after the button, so Tab moves from the button to the next control.
- No colour carries meaning here: the block is secondary text; errors keep their sentence.
- No address, tenant id, token or raw code appears in the block or its label.
- Text uses `.caption` with `fixedSize(horizontal: false, vertical: true)`, so it wraps at the largest macOS text size; the 460-point onboarding window scrolls (UX review).
- No motion.

## Tokens

System type scale only: `.caption` for the block, `.caption.weight(.semibold)` for its heading, `.callout` for the admin and protocol messages. Spacing: 4 pt inside the block, 8 pt between the button and the block (the existing `VStack` steps). Colour: `.secondary` for the block, the system accent on the prominent button. No new tokens, components or dependencies.

## Decision record

No experiment report was supplied. Options considered:

1. **The UX review body verbatim** (one paragraph: permission to read, save drafts and send; mail read on this Mac; tokens in the Keychain, never sent to Sentwise servers). Accurate, but it says nothing about the drafting service, which leaves the "nothing leaves the Mac" impression the review itself warned against for Google, and it has no revoke line, which the work order requires.
2. **One long paragraph with everything.** Rejected: in a caption under a button it reads as a wall, and VoiceOver users get the same wall.
3. **Picked: four short sentences in the order of the decision** (what is asked, where things go, the work note when it applies, how to undo). Each sentence is one fact, the drafting sentence matches the Google wording, and "kept in this Mac's Keychain" replaces "tokens" with a word a non-developer reads without stopping. "Keep this Mac signed in" is the plain reading of `offline_access`, which Microsoft's own screen shows as "maintain access to data you have given it access to"; naming it here means the browser page holds no surprise.

## Owner approval

| String | Where shown | Approved |
|---|---|---|
| `Before you continue` | Microsoft chooser block, heading | |
| `Microsoft will ask you to let Sentwise read your mail, save drafts, and send messages you approve, and to keep this Mac signed in.` | Chooser block | |
| `Mail is read on this Mac. Only the content needed to draft a reply, and up to 12 of your sent messages each time you learn your voice, goes to the Sentwise drafting service. Your sign-in is kept in this Mac's Keychain and is never sent to Sentwise servers.` | Chooser block | |
| `For a work or school account, your IT administrator may need to approve Sentwise first.` | Chooser block | |
| `You can remove Sentwise's access at any time in your Microsoft account.` | Chooser block | |
| `Your organization requires an administrator to approve Sentwise.` | Admin approval state | |
| `IMAP access is off for this mailbox. Your administrator needs to enable IMAP before Sentwise can connect.` | Protocol-disabled recovery | |
| `Sending is off for this mailbox. Your administrator needs to enable SMTP AUTH before Sentwise can connect.` | Protocol-disabled recovery | |
| `Sign in with Microsoft again to keep <address> connected.` | Reauthentication, saved mailbox | |
| `Microsoft sign-in expired or was revoked. Sign in with Microsoft again in Settings → Email Account.` | Mail-error detail on sync | |
| sentwise.ai/privacy "Outlook and Microsoft user data" section (below) | Landing page | |

## Privacy policy change list (sentwise-landing-page, `src/app/privacy/page.tsx`)

For the landing-page repo; this branch does not edit it. Ship it before the Microsoft flag is on in a public build, and not before: until then it would announce Outlook support (US-sign-in-first-10 constraint).

1. Insert a new section directly after the "Gmail and Google user data" section and before "Account, billing, support, and diagnostic data", with a source comment like the Google one: facts mirror the app (tokens in the Keychain this-device-only, no Sentwise server sees a Microsoft token or connects to the mailbox, Microsoft has no revoke endpoint for this app so disconnect deletes the local token and the page links to Microsoft's own pages). Ready-to-paste JSX:

```tsx
      <h2>Outlook and Microsoft user data</h2>
      <p>
        If you connect an Outlook.com, Hotmail, Live, or Microsoft 365 mailbox
        with <strong>Sign in with Microsoft</strong>, Sentwise asks Microsoft
        for these permissions: &ldquo;IMAP.AccessAsUser.All&rdquo; to read your
        mail and save drafts over IMAP, &ldquo;SMTP.Send&rdquo; to send the
        messages you approve, &ldquo;offline_access&rdquo; so this Mac stays
        signed in, and &ldquo;openid profile email&rdquo; so Sentwise knows
        which mailbox you authorized. With that access, Sentwise:
      </p>
      <ul>
        <li>
          reads your messages on your Mac, including your sent mail to learn how
          you write and the messages you choose to follow up on or reply to;
        </li>
        <li>saves drafts of replies and follow-ups for you to review;</li>
        <li>
          sends only the messages you approve, through your Microsoft account.
        </li>
      </ul>
      <p>
        Your Microsoft data is handled the same way as Gmail data above. Your
        mail is stored on your Mac in the App, and your Microsoft sign-in tokens
        are stored only in this Mac&rsquo;s macOS Keychain, set to this device
        only and never synced. No Sentwise server stores your mail, connects to
        your mailbox, or ever receives your Microsoft tokens. AI processing
        happens only for the messages you act on (or, if you turn on automatic
        drafting, the messages your own rules select): the text needed for that
        draft goes through our stateless inference relay to our model provider,
        as described above, and Sentwise does not retain it. Each time you
        learn or re-learn your voice, the App sends up to 12 of your recent
        sent messages the same way, and those are not retained either. We do
        not sell
        Microsoft user data, use it for advertising, or use it to train AI
        models.
      </p>
      <p>
        For a work or school account, your organization may require an IT
        administrator to approve Sentwise before you can connect. If you ask
        Sentwise for a note to send them, the note lists the permissions above
        and is created on your Mac; Sentwise does not send it anywhere.
      </p>
      <p>
        You can revoke Sentwise&rsquo;s access at any time. In the App, choose{" "}
        <strong>Disconnect</strong> or remove the mailbox in Settings &rarr;
        Email Account. Either way Sentwise deletes the Microsoft token from your
        Keychain, so the App can no longer reach that mailbox. Mail-related data
        the App kept on your Mac for that mailbox is erased only if you choose{" "}
        <strong>Disconnect &amp; Erase Local Data</strong> or{" "}
        <strong>Remove &amp; Erase Local Data</strong>;{" "}
        <strong>Disconnect Only</strong> and <strong>Remove Only</strong> keep
        it on your Mac.
        To remove Sentwise&rsquo;s permission on Microsoft&rsquo;s side, use{" "}
        <a href="https://account.live.com/consent/Manage">
          account.live.com/consent/Manage
        </a>{" "}
        for a personal account, or{" "}
        <a href="https://myapps.microsoft.com">myapps.microsoft.com</a> for a
        work or school account. After that the App stops reading and sending
        mail for that mailbox and asks you to sign in with Microsoft again.
      </p>
```

2. "The short version" names no mail provider today; leave it as is.
3. Bump the page's last-updated date, if it carries one, to the day the section ships.
4. Note for the landing-page builder: the em-dash in "What leaves your Mac, and when" ("draft —") is outside this change; leave it unless the owner asks.

Facts to verify against the shipped app before the landing-page PR merges: that both Disconnect choices and both Remove choices delete the Microsoft token (checked in code: `takeGoogleTokenForDisconnect` and `removeGoogleTokenForAccountRemoval` both remove the Microsoft token whatever `purgeLocalData` is), that only the "& Erase Local Data" choices erase local mail-related data (`purgeLocalData: true` in `EmailAccountSettingsView`), and that the button titles still match the bold names in the paragraph, and whether the app shows the two Microsoft removal links after Disconnect (architecture 4.2 says it should; not built yet, see follow-ups).

## Follow-ups (not in this branch)

- Disconnect on a Microsoft mailbox should show the removal link (`account.live.com/consent/Manage` or `myapps.microsoft.com`, by tenant) as the architecture specifies; no view does today. Suggested line for item 31: "T31-14 Disconnect of a Microsoft mailbox shows `To remove Sentwise's permission on Microsoft's side, open your Microsoft account.` with a link chosen by tenant (personal vs work)."
- The Google idle helper in `GoogleSignInConnectView.swift` still carries the pre-review text with an em-dash and "nothing is stored on our servers"; the UX review's replacement belongs to T135-4.

## Verification

- `swiftlint --strict` clean; `xcodebuild build-for-testing` (scheme Sentwise) builds with zero errors on the MacBook. Tests run in CI only.
- `MicrosoftConsentCopyTests` asserts the final strings, no placeholder markers or em-dashes, none of the forbidden claims, the VoiceOver label order, and the reauthorization details.
- Not yet done: light and dark renders at default and largest text size, and the keyboard and VoiceOver walk on Lucius' Mini (held while the Mini runs the desktop QA brief and the branch is unpushed).
